(lang dune 3.15)

(cram enable)

; The embedding libraries are installable as rivet_compcert.compcert_embed and
; rivet_compcert.compcert_embed_<target>. They are gated (see embed/dune), so
; the package is empty unless an embed gate is set. Installed, they require
; the rivet.<library> findlib names: install rivet first (see README.md).

(name rivet_compcert)

(package
 (name rivet_compcert)
 (synopsis "CompCert embedded in-process behind rivet's driver")
 (allow_empty))
