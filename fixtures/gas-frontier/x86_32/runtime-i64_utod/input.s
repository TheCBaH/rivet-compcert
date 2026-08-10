 .section .note.GNU-stack,"",%progbits
.text; .globl __compcert_i64_utod; .align 16; __compcert_i64_utod:
        fildll 4(%esp)
        cmpl $0, 8(%esp)
        jns 1f
        fadds LC1
1: ret
        .p2align 2
LC1: .long 0x5f800000
.type __compcert_i64_utod, @function; .size __compcert_i64_utod, . - __compcert_i64_utod
