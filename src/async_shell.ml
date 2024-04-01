open Core
open Poly
open Async
module Process = Shell.Process

type 'a with_process_flags = 'a Shell.with_process_flags
type 'a with_run_flags = 'a Shell.with_run_flags
type 'a with_test_flags = 'a Shell.with_test_flags
type 'a with_ssh_flags = 'a Shell.with_ssh_flags
type 'a with_sh_flags = 'a Shell.with_sh_flags
type 'a cmd = 'a Shell.cmd
type ('a, 'ret) sh_cmd = ('a, 'ret) Shell.sh_cmd

let read_stream =
  let rev_concat xs = String.concat (List.rev xs) in
  let split_lines parts =
    Stream.create (fun tail ->
      let rec loop acc next =
        match next, acc with
        | Stream.Nil, [] -> Tail.close_exn tail
        | Stream.Nil, xs ->
          Tail.extend tail (rev_concat xs);
          Tail.close_exn tail
        | Stream.Cons (x, rest), xs ->
          (match String.lsplit2 ~on:'\n' x with
           | Some (x, x') ->
             let x =
               let len = String.length x in
               if len >= 1 && x.[len - 1] = '\r'
               then String.sub x ~pos:0 ~len:(len - 1)
               else x
             in
             Tail.extend tail (rev_concat (x :: xs));
             loop [] (Stream.Cons (x', rest))
           | None -> Stream.next rest >>> loop (x :: xs))
      in
      Stream.next parts >>> loop [])
  in
  fun f cmd ->
    let output = Tail.create () in
    let reader =
      Process.callback
        ~add:(fun s len ->
          Thread_safe.run_in_async_exn (fun () ->
            Tail.extend output (Substring.to_string (Substring.create s ~len))))
        ~flush:(fun () -> Thread_safe.run_in_async_exn (fun () -> Tail.close_exn output))
    in
    don't_wait_for (In_thread.run (fun () -> f cmd reader));
    split_lines (Tail.collect output)
;;

let run_gen reader =
  Process.run_k (fun f prog args ->
    In_thread.run (fun () -> f (Process.cmd prog args) reader))
;;

let run = run_gen Process.discard
let run_lines ?eol = run_gen (Process.lines ?eol ())
let run_full = run_gen Process.content
let run_full_and_error = run_gen Process.content_and_stderr
let run_one_line ?eol = run_gen (Process.one_line ?eol ())
let run_one_line_exn ?eol = run_gen (Process.one_line_exn ?eol ())
let run_first_line ?eol = run_gen (Process.head ?eol ())
let run_first_line_exn ?eol = run_gen (Process.head_exn ?eol ())

let run_lines_stream =
  Process.run_k (fun f prog args -> read_stream f (Process.cmd prog args))
;;

let test =
  Process.test_k (fun f prog args -> In_thread.run (fun () -> f (Process.cmd prog args)))
;;

let k_shell_command k f ?strict_errors fmt =
  ksprintf (fun command -> k f (Process.shell ?strict_errors command)) fmt
;;

let sh_gen ?strict_errors reader =
  Process.run_k
    (k_shell_command ?strict_errors (fun f cmd -> In_thread.run (fun () -> f cmd reader)))
;;

let sh ?strict_errors = sh_gen Process.discard ?strict_errors
let sh_first_line ?strict_errors = sh_gen (Process.head ()) ?strict_errors
let sh_first_line_exn ?strict_errors = sh_gen (Process.head_exn ()) ?strict_errors
let sh_one_line ?strict_errors = sh_gen (Process.one_line ()) ?strict_errors
let sh_one_line_exn ?strict_errors = sh_gen (Process.one_line_exn ()) ?strict_errors
let sh_lines ?strict_errors = sh_gen (Process.lines ()) ?strict_errors
let sh_full ?strict_errors = sh_gen Process.content ?strict_errors
let sh_full_and_error ?strict_errors = sh_gen Process.content_and_stderr ?strict_errors

let sh_lines_stream ?strict_errors =
  Process.run_k (k_shell_command read_stream) ?strict_errors
;;

let sh_test ?strict_errors =
  Process.test_k
    (k_shell_command ?strict_errors (fun f cmd -> In_thread.run (fun () -> f cmd)))
;;

let k_remote_command k f ?ssh_options ?user ~host fmt =
  ksprintf
    (fun command ->
      k
        f
        (Process.make_ssh_command ~quote_args:false ?ssh_options ?user ~host [ command ]))
    fmt
;;

let ssh_gen reader ?ssh_options ?user ~host =
  Process.run_k
    (k_remote_command
       (fun f cmd -> In_thread.run (fun () -> f cmd reader))
       ?ssh_options
       ?user
       ~host)
;;

let ssh ?ssh_options = ssh_gen Process.discard ?ssh_options
let ssh_first_line ?ssh_options = ssh_gen (Process.head ()) ?ssh_options
let ssh_first_line_exn ?ssh_options = ssh_gen (Process.head_exn ()) ?ssh_options
let ssh_one_line ?ssh_options = ssh_gen (Process.one_line ()) ?ssh_options
let ssh_one_line_exn ?ssh_options = ssh_gen (Process.one_line_exn ()) ?ssh_options
let ssh_lines ?ssh_options = ssh_gen (Process.lines ()) ?ssh_options
let ssh_full ?ssh_options = ssh_gen Process.content ?ssh_options
let ssh_full_and_error ?ssh_options = ssh_gen Process.content_and_stderr ?ssh_options

let ssh_lines_stream ?ssh_options ?user ~host =
  Process.run_k (k_remote_command read_stream ?ssh_options ?user ~host)
;;

let ssh_test ?ssh_options ?user ~host =
  Process.test_k
    (k_remote_command
       (fun f cmd -> In_thread.run (fun () -> f cmd))
       ?ssh_options
       ?user
       ~host)
;;

let protect_path path = if String.is_prefix ~prefix:"-" path then "./" ^ path else path

let mkdir ?p ?perm path =
  let p = Option.map p ~f:(fun () -> "-p") in
  let mode = Option.map perm ~f:(sprintf "-m=%o") in
  run "mkdir" (List.filter_opt [ p; mode; Some (protect_path path) ])
;;

let scp ?(compress = false) ?(recurse = false) ?user ~host f t =
  let user_arg = Option.value_map user ~default:"" ~f:(fun user -> user ^ "@") in
  let args = [ f; user_arg ^ host ^ ":" ^ t ] in
  let args = if recurse then "-r" :: args else args in
  let args = if compress then "-C" :: args else args in
  run "scp" args
;;
