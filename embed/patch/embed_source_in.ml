(* Injected into the embed variant of CompCert (see ../compcert-embed-sync.sh).

   [Parse.read_file] reads the preprocessed C source with exactly the four
   channel functions shadowed below. A name registered in [files] is served
   from memory; any other name falls through to the real file system, so the
   unmodified [Frontend.parse_c_file] works for both. *)

let files : (string, string) Hashtbl.t = Hashtbl.create 1

type in_channel = File of Stdlib.in_channel | Mem of string

let open_in_bin n =
  match Hashtbl.find_opt files n with Some s -> Mem s | None -> File (Stdlib.open_in_bin n)

let in_channel_length = function File ic -> Stdlib.in_channel_length ic | Mem s -> String.length s

let really_input_string ic n =
  match ic with File ic -> Stdlib.really_input_string ic n | Mem s -> String.sub s 0 n

let close_in = function File ic -> Stdlib.close_in ic | Mem _ -> ()
