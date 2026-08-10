 .section .note.GNU-stack,"",%progbits
.text; .globl __compcert_i64_umod; .align 16; __compcert_i64_umod:
        pushl %ebp
        pushl %esi
        pushl %edi
        call __compcert_i64_udivmod
        popl %edi
        popl %esi
        popl %ebp
        ret
.type __compcert_i64_umod, @function; .size __compcert_i64_umod, . - __compcert_i64_umod
