(** Where each corpus is committed: [fixtures/corpus/<suite>/<target>/]. *)

val c : Repo.t -> Target.t -> Fpath.t
val c_assemble : Repo.t -> Target.t -> Fpath.t
val c_gcc : Repo.t -> Target.t -> Fpath.t
val regression : Repo.t -> Target.t -> Fpath.t
val compression : Repo.t -> Target.t -> Fpath.t
