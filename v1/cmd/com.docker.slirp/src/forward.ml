open Utils

let src =
  let src = Logs.Src.create "port forward" ~doc:"forward local ports to the VM" in
  Logs.Src.set_level src (Some Logs.Info);
  src

module Log = (val Logs.src_log src : Logs.LOG)

let finally f g =
  let open Lwt.Infix in
  Lwt.catch (fun () -> f () >>= fun r -> g () >>= fun () -> Lwt.return r) (fun e -> g () >>= fun () -> Lwt.fail e)

module Result = struct
  include Result
  let return x = Ok x
  let errorf fmt = Printf.ksprintf (fun s -> Error (`Msg s)) fmt
end

module Port = struct
  module M = struct
    type t = int
    let compare (a: t) (b: t) = Pervasives.compare a b
  end
  include M
  module Map = Map.Make(M)
  module Set = Set.Make(M)
  let of_string x =
    try
      let x = int_of_string x in
      if x < 0 || x > 65535
      then Result.errorf "port out of range: 0 <= %d <= 65536" x
      else Result.return x
    with
    | _ -> Result.errorf "port is not an integer: '%s'" x
end

module Local = struct
  module M = struct
    type t = [
      | `Ip of Ipaddr.V4.t * Port.t
      | `Unix of string
    ]
    let compare = compare
  end
  include M
  module Map = Map.Make(M)
  module Set = Set.Make(M)

  let to_string = function
    | `Ip (addr, port) -> Printf.sprintf "%s:%d" (Ipaddr.V4.to_string addr) port
    | `Unix path -> "unix:" ^ path
end

module Make(S: Network_stack.S) = struct

type t = {
  local: Local.t;
  remote_ip: Ipaddr.V4.t;
  remote_port: Port.t;
  mutable fd: Lwt_unix.file_descr option;
}

type key = Local.t

let get_key t = t.local

module Map = Local.Map

type context = S.t

let to_string t = Printf.sprintf "%s:%s:%d" (Local.to_string t.local) (Ipaddr.V4.to_string t.remote_ip) t.remote_port

let description_of_format = "'[local ip:]local port:IPv4 address of remote:remote port' or 'unix:local path:IPv4 address of remote: remote port'"

let start stack t =
  let addr, fd = match t.local with
    | `Ip (local_ip, local_port) ->
      let addr = Lwt_unix.ADDR_INET(Unix.inet_addr_of_string (Ipaddr.V4.to_string local_ip), local_port) in
      let fd = Lwt_unix.socket Lwt_unix.PF_INET Lwt_unix.SOCK_STREAM 0 in
      addr, fd
    | `Unix path ->
      let addr = Lwt_unix.ADDR_UNIX(path) in
      let fd = Lwt_unix.socket Lwt_unix.PF_UNIX Lwt_unix.SOCK_STREAM 0 in
      addr, fd in
  Lwt_unix.setsockopt fd Lwt_unix.SO_REUSEADDR true;
  let open Lwt.Infix in
  (* On failure here, we must close the fd *)
  Lwt.catch
    (fun () ->
       Lwt_unix.bind fd addr;
       Lwt_unix.listen fd 5;
       match t.local, Lwt_unix.getsockname fd with
       | `Ip (local_ip, _), Lwt_unix.ADDR_INET(_, local_port) ->
         let t = { t with local = `Ip(local_ip, local_port) } in
         let t = if t.remote_port = 0 then { t with remote_port = local_port } else t in
         Lwt.return (Result.Ok (t, fd))
       | `Unix _, Lwt_unix.ADDR_UNIX(_) ->
         Lwt.return (Result.Ok (t, fd))
       | _ ->
         Lwt.return (Result.Error (`Msg "failed to query local port"))
    ) (fun e ->
        Lwt_unix.close fd
        >>= fun () ->
        (* Pretty-print the most common exception *)
        let message = match e with
        | Unix.Unix_error(Unix.EADDRINUSE, _, _) -> "address already in use"
        | e -> Printexc.to_string e in
        Lwt.return (Result.Error (`Msg (Printf.sprintf "failed to bind port: %s" message)))
      )
  >>= function
  | Result.Error e -> Lwt.return (Result.Error e)
  | Result.Ok (t, fd) ->
    (* The `Forward.stop` function is in charge of closing the fd *)
    let t = { t with fd = Some fd } in
    let description = to_string t in
    let rec loop () =
      Lwt.catch (fun () ->
          Lwt_unix.accept fd
          >>= fun (local_fd, _) ->
          Lwt.return (Some local_fd)
        ) (function
          | Unix.Unix_error(Unix.EBADF, _, _) -> Lwt.return None
          | e ->
            Log.err (fun f -> f "%s: failed to accept: %s" description (Printexc.to_string e));
            Lwt.return None
        )
      >>= function
      | None ->
        Log.info (fun f -> f "%s: listening thread shutting down" description);
        Lwt.return ()
      | Some local_fd ->
        let local = Socket.TCPV4.of_fd ~description local_fd in
        let proxy () =
          finally (fun () ->
              S.TCPV4.create_connection (S.tcpv4 stack) (t.remote_ip,t.remote_port)
              >>= function
              | `Error e ->
                Log.err (fun f -> f "%s: failed to connect: %s" description (S.TCPV4.error_message e));
                Lwt.return ()
              | `Ok remote ->
                finally (fun () ->
                  (* proxy between local and remote *)
                  Log.info (fun f -> f "%s: connected" description);
                  Mirage_flow.proxy (module Clock) (module S.TCPV4_half_close) remote (module Socket.TCPV4) local ()
                  >>= function
                  | `Error (`Msg m) ->
                    Log.err (fun f -> f "%s proxy failed with %s" description m);
                    Lwt.return ()
                  | `Ok (l_stats, r_stats) ->
                    Log.info (fun f ->
                        f "%s closing: l2r = %s; r2l = %s" description
                          (Mirage_flow.CopyStats.to_string l_stats) (Mirage_flow.CopyStats.to_string r_stats)
                      );
                    Lwt.return ()
                ) (fun () ->
                  S.TCPV4_half_close.close remote
                )
            ) (fun () ->
              Socket.TCPV4.close local
              >>= fun () ->
              Log.info (fun f -> f "%s: closed forwarded connection" description);
              Lwt.return ()
            )
        in
        Lwt.async (fun () -> log_exception_continue (description ^ " proxy") proxy);
        loop () in
    Lwt.async loop;
    Lwt.return (Result.Ok t)

let stop t = match t.fd with
  | None -> Lwt.return ()
  | Some fd ->
    t.fd <- None;
    Log.info (fun f -> f "%s: closing listening socket" (to_string t));
    Lwt_unix.close fd

let of_string x =
  match (
    match Stringext.split ~on:':' x with
    | [ "unix"; path; remote_ip; remote_port ] ->
      Result.Ok (
        `Unix path,
        Ipaddr.V4.of_string remote_ip,
        Port.of_string remote_port
      )
    | [ local_ip; local_port; remote_ip; remote_port ] ->
      let local_ip = Ipaddr.V4.of_string local_ip in
      let local_port = Port.of_string local_port in
      begin match local_ip, local_port with
      | Some ip, Result.Ok port ->
        Result.Ok (
          `Ip (ip, port),
          Ipaddr.V4.of_string remote_ip,
          Port.of_string remote_port
        )
      | _, _ -> Result.Error (`Msg "Failed to parse local IP and port")
      end
    | [ local_port; remote_ip; remote_port ] ->
      begin match Port.of_string local_port with
      | Result.Error x -> Result.Error x
      | Result.Ok port ->
        Result.Ok (
          `Ip(Ipaddr.V4.of_string_exn "127.0.0.1", port),
          Ipaddr.V4.of_string remote_ip,
          Port.of_string remote_port
        )
      end
    | _ ->
      Result.Error (`Msg ("Failed to parse request, expected " ^ description_of_format))
  ) with
  | Result.Error x -> Result.Error x
  | Result.Ok (local, Some remote_ip, Result.Ok remote_port) ->
    Result.Ok { local; remote_ip; remote_port; fd = None }
  | Result.Ok (_, None, _) ->
    Result.Error (`Msg "Failed to parse remote IPv4 address")
  | Result.Ok (_, _, Result.Error (`Msg m)) ->
    Result.Error (`Msg ("Failed to parse remote port: " ^ m))
end
