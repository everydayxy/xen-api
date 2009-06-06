
(** Copyright (C) XenSource 2007 *)

open Http
open Pervasiveext
open Forkhelpers
open Helpers

module D = Debug.Debugger(struct let name="xapi" end)
open D

let host_backup = "/opt/xensource/libexec/host-backup"
let host_restore = "/opt/xensource/libexec/host-restore"

let host_backup_handler_core ~__context s =
  match 
	(with_logfile_fd "host-backup" 
	   (fun log_fd ->
		  let pid = safe_close_and_exec 
		    [ Dup2(s, Unix.stdout);
		      Dup2(log_fd, Unix.stderr) ] 
		    [ Unix.stdout; Unix.stderr ] host_backup [] in

          let waitpid () =
            match Unix.waitpid [Unix.WNOHANG] pid with
              | 0, _ -> false
              | _, Unix.WEXITED 0 -> true
              | _, Unix.WEXITED n -> raise (Subprocess_failed n)
              | _, _ -> raise (Subprocess_failed 0)
          in
            
          let t = ref (0.0) in

            while not (waitpid ()) do
              Thread.delay 2.0;
              t := !t -. 0.1;
              let progress = 0.9 *. (1.0 -. (exp !t)) in
                TaskHelper.set_progress ~__context progress
            done
       )
    )
  with
	| Success(log,()) ->
	    debug "host_backup succeeded - returned: %s" log;
	    ()
	| Failure(log,e) ->
	    debug "host_backup failed - host_backup returned: %s" log;
	    raise (Api_errors.Server_error (Api_errors.backup_script_failed, [log]))

let host_backup_handler (req: request) s = 
  req.close := true;
  Xapi_http.with_context "Downloading host backup" req s
    (fun __context ->
      Http_svr.headers s (Http.http_200_ok ());
      
      if on_oem __context && Pool_role.is_master ()
      then
        begin
          List.iter (fun (_,db)-> Db_connections.force_flush_all db) (Db_connections.get_dbs_and_gen_counts());
          Threadext.Mutex.execute 
            Db_lock.global_flush_mutex 
            (fun () -> 
              host_backup_handler_core ~__context s
            )
        end
      else
        begin
          host_backup_handler_core ~__context s 
        end
    )

(** Helper function to prevent double-closes of file descriptors 
    TODO: this function was copied from util/sha1sum.ml, and should
          really go in a shared lib somewhere
*)
let close to_close fd = 
  if List.mem fd !to_close then Unix.close fd;
  to_close := List.filter (fun x -> fd <> x) !to_close 

let host_restore_handler (req: request) s = 
  req.close := true;
  Xapi_http.with_context "Uploading host backup" req s
    (fun __context ->
      Http_svr.headers s (Http.http_200_ok ());

      let out_pipe, in_pipe = Unix.pipe () in
      Unix.set_close_on_exec in_pipe;
      let to_close = ref [ out_pipe; in_pipe ] in
      let close = close to_close in
      (* Lets be paranoid about closing fds *)
      
      finally
        (fun () ->
	  (* XXX: ideally need to log this stuff *)
          let result =  with_logfile_fd "host-restore-log"
	    (fun log_fd ->
	      let pid = safe_close_and_exec 
		[ Dup2(out_pipe, Unix.stdin);
		  Dup2(log_fd, Unix.stdout);
		  Dup2(log_fd, Unix.stderr) ]
		[ Unix.stdin; Unix.stdout; Unix.stderr ] 
                host_restore [] in
              
              close out_pipe;
              
              finally
                (fun () ->
                  debug "Host restore: reading backup...";
                  let copied_bytes = match req.content_length with 
                    | Some i ->
                        debug "got content-length of %s" (Int64.to_string i);
                        Unixext.copy_file ~limit:i s in_pipe 
                    | None -> Unixext.copy_file s in_pipe
                  in
                  debug "Host restore: read %s bytes of backup..." 
                    (Int64.to_string copied_bytes)
                )
                (fun () -> 
                  close in_pipe;
                  waitpid pid
                )     
            )
          in
          
	  match result with
	    | Success _ -> debug "restore script exitted successfully"
	    | Failure (log, exn) ->
	        debug "host-restore script failed with output: %s" log;
	        raise (Api_errors.Server_error (Api_errors.restore_script_failed, [log]))               )
        (fun () -> List.iter close !to_close)
    )
