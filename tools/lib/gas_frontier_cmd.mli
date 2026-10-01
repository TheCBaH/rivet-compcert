(** [gas-frontier regen] - re-record the GNU as outcome for CompCert's own
    assembly, the frontier of what rivet's assembler is measured against.

    Every case under [fixtures/gas-frontier/<target>/] names its source in
    [origin.txt]: a committed ccomp fixture, or a CompCert runtime file that is
    preprocessed from the export tarball ([make compcert-fetch]). Each is
    re-derived and re-assembled in place, so [git diff] is the check. A GNU as
    rejection is recorded evidence, not a failure. *)

val regen : Repo.t -> Command.t
