(* Injected into the embed variant of CompCert (see ../compcert-embed-sync.sh).

   [Configuration] locates and reads compcert.ini while it is being
   initialized, and exits if the file is missing. Shadowing [Sys.getenv] makes
   its existing COMPCERT_CONFIG branch pick a placeholder name without touching
   the file system, and shadowing [Readconfig] serves every key from
   [Embed_config_data], generated from the target's compcert.ini when the
   variant tree is synced. *)

module Sys = struct
  include Stdlib.Sys

  let getenv k = if k = "COMPCERT_CONFIG" then "<embedded>" else getenv k
end

module Readconfig = struct
  include Readconfig

  let read_config_file (_ : string) = ()
  let key_val k = List.assoc_opt k Embed_config_data.table
end
