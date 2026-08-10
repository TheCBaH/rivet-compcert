 .section .note.GNU-stack,"",%progbits
.text; .globl __compcert_i64_dtou; .align 16; __compcert_i64_dtou:
        ucomisd .LC1(%rip), %xmm0
        jnb 1f
        cvttsd2siq %xmm0, %rax
        ret
1: subsd .LC1(%rip), %xmm0
        cvttsd2siq %xmm0, %rax
        addq .LC2(%rip), %rax
        ret
.type __compcert_i64_dtou, @function; .size __compcert_i64_dtou, . - __compcert_i64_dtou
.section .rodata
        .p2align 3
.LC1: .quad 0x43e0000000000000
.LC2: .quad 0x8000000000000000
