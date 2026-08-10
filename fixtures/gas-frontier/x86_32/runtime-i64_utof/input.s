 .section .note.GNU-stack,"",%progbits
.text; .globl __compcert_i64_utof; .align 16; __compcert_i64_utof:
        fildll 4(%esp)
        cmpl $0, 8(%esp)
        jns 1f
        fadds LC1
1: fstps 4(%esp)
        flds 4(%esp)
        ret
        .p2align 2
LC1: .long 0x5f800000
.type __compcert_i64_utof, @function; .size __compcert_i64_utof, . - __compcert_i64_utof
