[@@@ai_disclosure "ai-generated"]
[@@@ai_provider "Anthropic, OpenAI"]

(* The differential gate over the CompCert corpus: Rivet's {!Differential.Make} instantiated for
   fixtures/compcert-3.17, where a case is any directory with a manifest, and the transcripts
   that pin it. *)

include Differential.Make (struct
  let root = "../../fixtures/compcert-3.17"
  let targets = [ "x86_32"; "x86_64"; "arm"; "aarch64"; "riscv32"; "riscv64" ]
  let is_case dir = Sys.file_exists (Filename.concat dir "manifest.txt")
end)

let%expect_test "every bound segment matches the controlled reference link" =
  List.iter (fun c -> List.iter (fun t -> check_bytes c t) (targets_for c)) (cases ());
  [%expect
    {|
    args_arith   x86_32   .text 130
    args_arith   x86_64   .text 103
    args_arith   arm      .text 120
    args_arith   aarch64  .text 104
    args_arith   riscv32  .text 128
    args_arith   riscv64  .text 128
    cond_select  x86_32   .text 94
    cond_select  x86_64   .text 95
    cond_select  arm      .text 120
    cond_select  aarch64  .text 108
    cond_select  riscv32  .text 108
    cond_select  riscv64  .text 108
    cross_bss    x86_32   .text 27, .bss 4 bytes (nobits)
    cross_bss    x86_64   .text 34, .bss 4 bytes (nobits)
    cross_bss    arm      .text 48, .bss 4 bytes (nobits)
    cross_bss    aarch64  .text 40, .bss 4 bytes (nobits)
    cross_bss    riscv32  .text 48, .bss 4 bytes (nobits)
    cross_bss    riscv64  .text 48, .bss 4 bytes (nobits)
    cross_call   x86_32   .text 63
    cross_call   x86_64   .text 64
    cross_call   arm      .text 72
    cross_call   aarch64  .text 56
    cross_call   riscv32  .text 76
    cross_call   riscv64  .text 76
    cross_data   x86_32   .text 27, .data 4
    cross_data   x86_64   .text 34, .data 4
    cross_data   arm      .text 48, .data 4
    cross_data   aarch64  .text 40, .data 4
    cross_data   riscv32  .text 48, .data 4
    cross_data   riscv64  .text 48, .data 4
    direct_call  x86_32   .text 63
    direct_call  x86_64   .text 64
    direct_call  arm      .text 72
    direct_call  aarch64  .text 56
    direct_call  riscv32  .text 76
    direct_call  riscv64  .text 76
    global_ldst  x86_32   .text 27, .data 4
    global_ldst  x86_64   .text 34, .data 4
    global_ldst  arm      .text 48, .data 4
    global_ldst  aarch64  .text 40, .data 4
    global_ldst  riscv32  .text 48, .data 4
    global_ldst  riscv64  .text 48, .data 4
    i64_divmod   x86_32   .text 420, .data 32
    loop         x86_32   .text 43
    loop         x86_64   .text 49
    loop         arm      .text 68
    loop         aarch64  .text 60
    loop         riscv32  .text 64
    loop         riscv64  .text 64
    return42     x86_32   .text 19
    return42     x86_64   .text 23
    return42     arm      .text 32
    return42     aarch64  .text 24
    return42     riscv32  .text 32
    return42     riscv64  .text 32 |}]

let%expect_test "diagnostic spelling agrees with objdump after normalization" =
  List.iter (fun c -> List.iter (fun t -> check_disasm c t) (targets_for c)) (cases ());
  [%expect
    {|
    args_arith   x86_32   36 lines agree
    args_arith   x86_64   26 lines agree
    args_arith   arm      30 lines agree
    args_arith   aarch64  26 lines agree
    args_arith   riscv32  32 lines agree
    args_arith   riscv64  32 lines agree
    cond_select  x86_32   29 lines agree
    cond_select  x86_64   27 lines agree
    cond_select  arm      30 lines agree
    cond_select  aarch64  27 lines agree
    cond_select  riscv32  27 lines agree
    cond_select  riscv64  27 lines agree
    cross_bss    x86_32   8 lines agree (2 relocated operands compared as records instead)
    cross_bss    x86_64   8 lines agree (2 relocated operands compared as records instead)
    cross_bss    arm      12 lines agree (2 relocated operands compared as records instead)
    cross_bss    aarch64  10 lines agree (4 relocated operands compared as records instead)
    cross_bss    riscv32  12 lines agree (6 relocated operands compared as records instead)
    cross_bss    riscv64  12 lines agree (6 relocated operands compared as records instead)
    cross_call   x86_32   16 lines agree (1 relocated operand compared as records instead)
    cross_call   x86_64   14 lines agree (1 relocated operand compared as records instead)
    cross_call   arm      18 lines agree (1 relocated operand compared as records instead)
    cross_call   aarch64  14 lines agree (1 relocated operand compared as records instead)
    cross_call   riscv32  19 lines agree (2 relocated operands compared as records instead)
    cross_call   riscv64  19 lines agree (2 relocated operands compared as records instead)
    cross_data   x86_32   8 lines agree (2 relocated operands compared as records instead)
    cross_data   x86_64   8 lines agree (2 relocated operands compared as records instead)
    cross_data   arm      12 lines agree (2 relocated operands compared as records instead)
    cross_data   aarch64  10 lines agree (4 relocated operands compared as records instead)
    cross_data   riscv32  12 lines agree (6 relocated operands compared as records instead)
    cross_data   riscv64  12 lines agree (6 relocated operands compared as records instead)
    direct_call  x86_32   16 lines agree (1 relocated operand compared as records instead)
    direct_call  x86_64   14 lines agree (1 relocated operand compared as records instead)
    direct_call  arm      18 lines agree (1 relocated operand compared as records instead)
    direct_call  aarch64  14 lines agree (1 relocated operand compared as records instead)
    direct_call  riscv32  19 lines agree (2 relocated operands compared as records instead)
    direct_call  riscv64  19 lines agree (2 relocated operands compared as records instead)
    global_ldst  x86_32   8 lines agree (2 relocated operands compared as records instead)
    global_ldst  x86_64   8 lines agree (2 relocated operands compared as records instead)
    global_ldst  arm      12 lines agree (2 relocated operands compared as records instead)
    global_ldst  aarch64  10 lines agree (4 relocated operands compared as records instead)
    global_ldst  riscv32  12 lines agree (6 relocated operands compared as records instead)
    global_ldst  riscv64  12 lines agree (6 relocated operands compared as records instead)
    i64_divmod   x86_32   DIFFERS
        ours:    jge 170
        objdump: jge 26
    i64_divmod   x86_32   DIFFERS
        ours:    jge 193
        objdump: jge 49
    i64_divmod   x86_32   DIFFERS
        ours:    jge 209
        objdump: jge 65
    i64_divmod   x86_32   DIFFERS
        ours:    jge 250
        objdump: jge 26
    i64_divmod   x86_32   DIFFERS
        ours:    jge 271
        objdump: jge 47
    i64_divmod   x86_32   DIFFERS
        ours:    jge 287
        objdump: jge 63
    i64_divmod   x86_32   DIFFERS
        ours:    jne 338
        objdump: jne 34
    i64_divmod   x86_32   DIFFERS
        ours:    jne 354
        objdump: jne 50
    i64_divmod   x86_32   DIFFERS
        ours:    jb 417
        objdump: jb 113
    i64_divmod   x86_32   DIFFERS
        ours:    jae 414
        objdump: jae 110
    i64_divmod   x86_32   DIFFERS
        ours:    jmp 370
        objdump: jmp 66
    loop         x86_32   15 lines agree
    loop         x86_64   15 lines agree
    loop         arm      17 lines agree
    loop         aarch64  15 lines agree
    loop         riscv32  16 lines agree
    loop         riscv64  16 lines agree
    return42     x86_32   6 lines agree
    return42     x86_64   6 lines agree
    return42     arm      8 lines agree
    return42     aarch64  6 lines agree
    return42     riscv32  8 lines agree
    return42     riscv64  8 lines agree |}]

let%expect_test "canonical disassembly reassembles to the same bytes" =
  List.iter (fun c -> List.iter (fun t -> check_round_trip c t) (targets_for c)) (cases ());
  [%expect
    {|
    args_arith   x86_32   130 bytes reproduced
    args_arith   x86_64   103 bytes reproduced
    args_arith   arm      120 bytes reproduced
    args_arith   aarch64  104 bytes reproduced
    args_arith   riscv32  128 bytes reproduced
    args_arith   riscv64  128 bytes reproduced
    cond_select  x86_32   94 bytes reproduced
    cond_select  x86_64   95 bytes reproduced
    cond_select  arm      120 bytes reproduced
    cond_select  aarch64  108 bytes reproduced
    cond_select  riscv32  108 bytes reproduced
    cond_select  riscv64  108 bytes reproduced
    cross_bss    x86_32   (multi-source: round-trip comparison not yet implemented per unit)
    cross_bss    x86_64   (multi-source: round-trip comparison not yet implemented per unit)
    cross_bss    arm      (multi-source: round-trip comparison not yet implemented per unit)
    cross_bss    aarch64  (multi-source: round-trip comparison not yet implemented per unit)
    cross_bss    riscv32  (multi-source: round-trip comparison not yet implemented per unit)
    cross_bss    riscv64  (multi-source: round-trip comparison not yet implemented per unit)
    cross_call   x86_32   (multi-source: round-trip comparison not yet implemented per unit)
    cross_call   x86_64   (multi-source: round-trip comparison not yet implemented per unit)
    cross_call   arm      (multi-source: round-trip comparison not yet implemented per unit)
    cross_call   aarch64  (multi-source: round-trip comparison not yet implemented per unit)
    cross_call   riscv32  (multi-source: round-trip comparison not yet implemented per unit)
    cross_call   riscv64  (multi-source: round-trip comparison not yet implemented per unit)
    cross_data   x86_32   (multi-source: round-trip comparison not yet implemented per unit)
    cross_data   x86_64   (multi-source: round-trip comparison not yet implemented per unit)
    cross_data   arm      (multi-source: round-trip comparison not yet implemented per unit)
    cross_data   aarch64  (multi-source: round-trip comparison not yet implemented per unit)
    cross_data   riscv32  (multi-source: round-trip comparison not yet implemented per unit)
    cross_data   riscv64  (multi-source: round-trip comparison not yet implemented per unit)
    direct_call  x86_32   63 bytes reproduced
    direct_call  x86_64   64 bytes reproduced
    direct_call  arm      72 bytes reproduced
    direct_call  aarch64  56 bytes reproduced
    direct_call  riscv32  76 bytes reproduced
    direct_call  riscv64  76 bytes reproduced
    global_ldst  x86_32   27 bytes reproduced
    global_ldst  x86_64   34 bytes reproduced
    global_ldst  arm      48 bytes reproduced
    global_ldst  aarch64  40 bytes reproduced
    global_ldst  riscv32  48 bytes reproduced
    global_ldst  riscv64  48 bytes reproduced
    i64_divmod   x86_32   (multi-source: round-trip comparison not yet implemented per unit)
    loop         x86_32   43 bytes reproduced
    loop         x86_64   49 bytes reproduced
    loop         arm      68 bytes reproduced
    loop         aarch64  60 bytes reproduced
    loop         riscv32  64 bytes reproduced
    loop         riscv64  64 bytes reproduced
    return42     x86_32   19 bytes reproduced
    return42     x86_64   23 bytes reproduced
    return42     arm      32 bytes reproduced
    return42     aarch64  24 bytes reproduced
    return42     riscv32  32 bytes reproduced
    return42     riscv64  32 bytes reproduced |}]

let%expect_test "fixup observations classify to exactly the measured relocations" =
  List.iter (fun c -> List.iter (fun t -> check_relocs c t) (targets_for c)) (cases ());
  [%expect
    {|
    args_arith   x86_32   0 linker-visible, 0 assembler-resolved
    args_arith   x86_64   0 linker-visible, 0 assembler-resolved
    args_arith   arm      0 linker-visible, 0 assembler-resolved
    args_arith   aarch64  0 linker-visible, 0 assembler-resolved
    args_arith   riscv32  0 linker-visible, 0 assembler-resolved
    args_arith   riscv64  0 linker-visible, 0 assembler-resolved
    cond_select  x86_32   0 linker-visible, 4 assembler-resolved
      .text+0x2b   pcrel8-branch    branch local  same-sec  assembler-resolved
      .text+0x31   pcrel8-branch    branch local  same-sec  assembler-resolved
      .text+0x41   pcrel8-branch    branch local  same-sec  assembler-resolved
      .text+0x47   pcrel8-branch    branch local  same-sec  assembler-resolved
    cond_select  x86_64   0 linker-visible, 4 assembler-resolved
      .text+0x2a   pcrel8-branch    branch local  same-sec  assembler-resolved
      .text+0x30   pcrel8-branch    branch local  same-sec  assembler-resolved
      .text+0x42   pcrel8-branch    branch local  same-sec  assembler-resolved
      .text+0x48   pcrel8-branch    branch local  same-sec  assembler-resolved
    cond_select  arm      0 linker-visible, 4 assembler-resolved
      .text+0x2c   pcrel-b26        branch local  same-sec  assembler-resolved
      .text+0x34   pcrel-b26        branch local  same-sec  assembler-resolved
      .text+0x48   pcrel-b26        branch local  same-sec  assembler-resolved
      .text+0x50   pcrel-b26        branch local  same-sec  assembler-resolved
    cond_select  aarch64  0 linker-visible, 4 assembler-resolved
      .text+0x24   pcrel-b19        branch local  same-sec  assembler-resolved
      .text+0x2c   pcrel-b26        branch local  same-sec  assembler-resolved
      .text+0x40   pcrel-b19        branch local  same-sec  assembler-resolved
      .text+0x48   pcrel-b26        branch local  same-sec  assembler-resolved
    cond_select  riscv32  0 linker-visible, 6 assembler-resolved
      .text+0x28   pcrel-b13        branch local  same-sec  assembler-resolved
      .text+0x30   pcrel-j21        branch local  same-sec  assembler-resolved
      .text+0x40   pcrel-b13        branch local  same-sec  assembler-resolved
      .text+0x48   pcrel-j21        branch local  same-sec  assembler-resolved
      .text+0x50   pcrel-b13        branch local  same-sec  assembler-resolved
      .text+0x58   pcrel-j21        branch local  same-sec  assembler-resolved
    cond_select  riscv64  0 linker-visible, 6 assembler-resolved
      .text+0x28   pcrel-b13        branch local  same-sec  assembler-resolved
      .text+0x30   pcrel-j21        branch local  same-sec  assembler-resolved
      .text+0x40   pcrel-b13        branch local  same-sec  assembler-resolved
      .text+0x48   pcrel-j21        branch local  same-sec  assembler-resolved
      .text+0x50   pcrel-b13        branch local  same-sec  assembler-resolved
      .text+0x58   pcrel-j21        branch local  same-sec  assembler-resolved
    cross_bss    x86_32   2 linker-visible, 0 assembler-resolved
      .text+0xb    abs32            data-address local  other-sec R_386_32
      .text+0x13   abs32            data-address local  other-sec R_386_32
    cross_bss    x86_64   2 linker-visible, 0 assembler-resolved
      .text+0xf    pcrel32-data     data-address local  other-sec R_X86_64_PC32
      .text+0x19   pcrel32-data     data-address local  other-sec R_X86_64_PC32
    cross_bss    arm      2 linker-visible, 0 assembler-resolved
      .text+0x10   movw-abs-nc      data-address local  other-sec R_ARM_MOVW_ABS_NC
      .text+0x14   movt-abs         data-address local  other-sec R_ARM_MOVT_ABS
    cross_bss    aarch64  4 linker-visible, 0 assembler-resolved
      .text+0x8    adrp-page        data-address local  other-sec R_AARCH64_ADR_PREL_PG_HI21
      .text+0xc    ldst32-lo12      data-address local  other-sec R_AARCH64_LDST32_ABS_LO12_NC
      .text+0x14   adrp-page        data-address local  other-sec R_AARCH64_ADR_PREL_PG_HI21
      .text+0x18   ldst32-lo12      data-address local  other-sec R_AARCH64_LDST32_ABS_LO12_NC
    cross_bss    riscv32  4 linker-visible, 0 assembler-resolved
      .text+0x10   pcrel-hi20       data-address local  other-sec R_RISCV_PCREL_HI20
      .text+0x14   pcrel-lo12-i     data-address local  same-sec  R_RISCV_PCREL_LO12_I
      .text+0x1c   pcrel-hi20       data-address local  other-sec R_RISCV_PCREL_HI20
      .text+0x20   pcrel-lo12-s     data-address local  same-sec  R_RISCV_PCREL_LO12_S
    cross_bss    riscv64  4 linker-visible, 0 assembler-resolved
      .text+0x10   pcrel-hi20       data-address local  other-sec R_RISCV_PCREL_HI20
      .text+0x14   pcrel-lo12-i     data-address local  same-sec  R_RISCV_PCREL_LO12_I
      .text+0x1c   pcrel-hi20       data-address local  other-sec R_RISCV_PCREL_HI20
      .text+0x20   pcrel-lo12-s     data-address local  same-sec  R_RISCV_PCREL_LO12_S
    cross_call   x86_32   1 linker-visible, 0 assembler-resolved
      .text+0x34   pcrel32-call     call   global same-sec  R_386_PC32
    cross_call   x86_64   1 linker-visible, 0 assembler-resolved
      .text+0x33   pcrel32-call     call   global same-sec  R_X86_64_PLT32
    cross_call   arm      1 linker-visible, 0 assembler-resolved
      .text+0x34   pcrel-call       call   global same-sec  R_ARM_CALL
    cross_call   aarch64  1 linker-visible, 0 assembler-resolved
      .text+0x24   pcrel-call26     call   global same-sec  R_AARCH64_CALL26
    cross_call   riscv32  1 linker-visible, 1 assembler-resolved
      .text+0x34   call-hi20        call   global same-sec  R_RISCV_CALL_PLT
      .text+0x38   call-lo12-i      call   global same-sec  assembler-resolved
    cross_call   riscv64  1 linker-visible, 1 assembler-resolved
      .text+0x34   call-hi20        call   global same-sec  R_RISCV_CALL_PLT
      .text+0x38   call-lo12-i      call   global same-sec  assembler-resolved
    cross_data   x86_32   2 linker-visible, 0 assembler-resolved
      .text+0xb    abs32            data-address global other-sec R_386_32
      .text+0x13   abs32            data-address global other-sec R_386_32
    cross_data   x86_64   2 linker-visible, 0 assembler-resolved
      .text+0xf    pcrel32-data     data-address global other-sec R_X86_64_PC32
      .text+0x19   pcrel32-data     data-address global other-sec R_X86_64_PC32
    cross_data   arm      2 linker-visible, 0 assembler-resolved
      .text+0x10   movw-abs-nc      data-address global other-sec R_ARM_MOVW_ABS_NC
      .text+0x14   movt-abs         data-address global other-sec R_ARM_MOVT_ABS
    cross_data   aarch64  4 linker-visible, 0 assembler-resolved
      .text+0x8    adrp-page        data-address global other-sec R_AARCH64_ADR_PREL_PG_HI21
      .text+0xc    ldst32-lo12      data-address global other-sec R_AARCH64_LDST32_ABS_LO12_NC
      .text+0x14   adrp-page        data-address global other-sec R_AARCH64_ADR_PREL_PG_HI21
      .text+0x18   ldst32-lo12      data-address global other-sec R_AARCH64_LDST32_ABS_LO12_NC
    cross_data   riscv32  4 linker-visible, 0 assembler-resolved
      .text+0x10   pcrel-hi20       data-address global other-sec R_RISCV_PCREL_HI20
      .text+0x14   pcrel-lo12-i     data-address local  same-sec  R_RISCV_PCREL_LO12_I
      .text+0x1c   pcrel-hi20       data-address global other-sec R_RISCV_PCREL_HI20
      .text+0x20   pcrel-lo12-s     data-address local  same-sec  R_RISCV_PCREL_LO12_S
    cross_data   riscv64  4 linker-visible, 0 assembler-resolved
      .text+0x10   pcrel-hi20       data-address global other-sec R_RISCV_PCREL_HI20
      .text+0x14   pcrel-lo12-i     data-address local  same-sec  R_RISCV_PCREL_LO12_I
      .text+0x1c   pcrel-hi20       data-address global other-sec R_RISCV_PCREL_HI20
      .text+0x20   pcrel-lo12-s     data-address local  same-sec  R_RISCV_PCREL_LO12_S
    direct_call  x86_32   1 linker-visible, 0 assembler-resolved
      .text+0x34   pcrel32-call     call   global same-sec  R_386_PC32
    direct_call  x86_64   1 linker-visible, 0 assembler-resolved
      .text+0x33   pcrel32-call     call   global same-sec  R_X86_64_PLT32
    direct_call  arm      1 linker-visible, 0 assembler-resolved
      .text+0x34   pcrel-call       call   global same-sec  R_ARM_CALL
    direct_call  aarch64  1 linker-visible, 0 assembler-resolved
      .text+0x24   pcrel-call26     call   global same-sec  R_AARCH64_CALL26
    direct_call  riscv32  1 linker-visible, 1 assembler-resolved
      .text+0x34   call-hi20        call   global same-sec  R_RISCV_CALL_PLT
      .text+0x38   call-lo12-i      call   global same-sec  assembler-resolved
    direct_call  riscv64  1 linker-visible, 1 assembler-resolved
      .text+0x34   call-hi20        call   global same-sec  R_RISCV_CALL_PLT
      .text+0x38   call-lo12-i      call   global same-sec  assembler-resolved
    global_ldst  x86_32   2 linker-visible, 0 assembler-resolved
      .text+0xb    abs32            data-address global other-sec R_386_32
      .text+0x13   abs32            data-address global other-sec R_386_32
    global_ldst  x86_64   2 linker-visible, 0 assembler-resolved
      .text+0xf    pcrel32-data     data-address global other-sec R_X86_64_PC32
      .text+0x19   pcrel32-data     data-address global other-sec R_X86_64_PC32
    global_ldst  arm      2 linker-visible, 0 assembler-resolved
      .text+0x10   movw-abs-nc      data-address global other-sec R_ARM_MOVW_ABS_NC
      .text+0x14   movt-abs         data-address global other-sec R_ARM_MOVT_ABS
    global_ldst  aarch64  4 linker-visible, 0 assembler-resolved
      .text+0x8    adrp-page        data-address global other-sec R_AARCH64_ADR_PREL_PG_HI21
      .text+0xc    ldst32-lo12      data-address global other-sec R_AARCH64_LDST32_ABS_LO12_NC
      .text+0x14   adrp-page        data-address global other-sec R_AARCH64_ADR_PREL_PG_HI21
      .text+0x18   ldst32-lo12      data-address global other-sec R_AARCH64_LDST32_ABS_LO12_NC
    global_ldst  riscv32  4 linker-visible, 0 assembler-resolved
      .text+0x10   pcrel-hi20       data-address global other-sec R_RISCV_PCREL_HI20
      .text+0x14   pcrel-lo12-i     data-address local  same-sec  R_RISCV_PCREL_LO12_I
      .text+0x1c   pcrel-hi20       data-address global other-sec R_RISCV_PCREL_HI20
      .text+0x20   pcrel-lo12-s     data-address local  same-sec  R_RISCV_PCREL_LO12_S
    global_ldst  riscv64  4 linker-visible, 0 assembler-resolved
      .text+0x10   pcrel-hi20       data-address global other-sec R_RISCV_PCREL_HI20
      .text+0x14   pcrel-lo12-i     data-address local  same-sec  R_RISCV_PCREL_LO12_I
      .text+0x1c   pcrel-hi20       data-address global other-sec R_RISCV_PCREL_HI20
      .text+0x20   pcrel-lo12-s     data-address local  same-sec  R_RISCV_PCREL_LO12_S
    i64_divmod   x86_32   16 linker-visible, 11 assembler-resolved
      .text+0x14   abs32            data-address global other-sec R_386_32
      .text+0x1a   abs32            data-address global other-sec R_386_32
      .text+0x20   abs32            data-address global other-sec R_386_32
      .text+0x26   abs32            data-address global other-sec R_386_32
      .text+0x3a   pcrel32-call     call   global same-sec  R_386_PC32
      .text+0x3f   abs32            data-address global other-sec R_386_32
      .text+0x45   abs32            data-address global other-sec R_386_32
      .text+0x4b   abs32            data-address global other-sec R_386_32
      .text+0x51   abs32            data-address global other-sec R_386_32
      .text+0x56   abs32            data-address global other-sec R_386_32
      .text+0x5c   abs32            data-address global other-sec R_386_32
      .text+0x70   pcrel32-call     call   global same-sec  R_386_PC32
      .text+0x75   abs32            data-address global other-sec R_386_32
      .text+0x7b   abs32            data-address global other-sec R_386_32
      .text+0x9c   pcrel8-branch    branch local  same-sec  assembler-resolved
      .text+0xb3   pcrel8-branch    branch local  same-sec  assembler-resolved
      .text+0xc2   pcrel32-call     call   global same-sec  R_386_PC32
      .text+0xc9   pcrel8-branch    branch local  same-sec  assembler-resolved
      .text+0xec   pcrel8-branch    branch local  same-sec  assembler-resolved
      .text+0x101  pcrel8-branch    branch local  same-sec  assembler-resolved
      .text+0x110  pcrel32-call     call   global same-sec  R_386_PC32
      .text+0x117  pcrel8-branch    branch local  same-sec  assembler-resolved
      .text+0x136  pcrel8-branch    branch local  same-sec  assembler-resolved
      .text+0x16d  pcrel8-branch    branch local  same-sec  assembler-resolved
      .text+0x182  pcrel8-branch    branch local  same-sec  assembler-resolved
      .text+0x194  pcrel8-branch    branch local  same-sec  assembler-resolved
      .text+0x1a3  pcrel8-branch    branch local  same-sec  assembler-resolved
    loop         x86_32   0 linker-visible, 2 assembler-resolved
      .text+0x1e   pcrel8-branch    branch local  same-sec  assembler-resolved
      .text+0x26   pcrel8-branch    branch local  same-sec  assembler-resolved
    loop         x86_64   0 linker-visible, 2 assembler-resolved
      .text+0x21   pcrel8-branch    branch local  same-sec  assembler-resolved
      .text+0x2b   pcrel8-branch    branch local  same-sec  assembler-resolved
    loop         arm      0 linker-visible, 2 assembler-resolved
      .text+0x28   pcrel-b26        branch local  same-sec  assembler-resolved
      .text+0x34   pcrel-b26        branch local  same-sec  assembler-resolved
    loop         aarch64  0 linker-visible, 2 assembler-resolved
      .text+0x20   pcrel-b19        branch local  same-sec  assembler-resolved
      .text+0x2c   pcrel-b26        branch local  same-sec  assembler-resolved
    loop         riscv32  0 linker-visible, 2 assembler-resolved
      .text+0x24   pcrel-b13        branch local  same-sec  assembler-resolved
      .text+0x30   pcrel-j21        branch local  same-sec  assembler-resolved
    loop         riscv64  0 linker-visible, 2 assembler-resolved
      .text+0x24   pcrel-b13        branch local  same-sec  assembler-resolved
      .text+0x30   pcrel-j21        branch local  same-sec  assembler-resolved
    return42     x86_32   0 linker-visible, 0 assembler-resolved
    return42     x86_64   0 linker-visible, 0 assembler-resolved
    return42     arm      0 linker-visible, 0 assembler-resolved
    return42     aarch64  0 linker-visible, 0 assembler-resolved
    return42     riscv32  0 linker-visible, 0 assembler-resolved
    return42     riscv64  0 linker-visible, 0 assembler-resolved |}]
