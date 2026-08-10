 .section .note.GNU-stack,"",%progbits
.text; .globl __compcert_i64_udiv; .align 16; __compcert_i64_udiv:
        pushl %ebp
        pushl %esi
        pushl %edi
        call __compcert_i64_udivmod
        movl %esi, %eax
        movl %edi, %edx
        popl %edi
        popl %esi
        popl %ebp
        ret
.type __compcert_i64_udiv, @function; .size __compcert_i64_udiv, . - __compcert_i64_udiv
