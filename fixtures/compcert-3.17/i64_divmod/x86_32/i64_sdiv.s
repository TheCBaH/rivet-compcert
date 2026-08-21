 .section .note.GNU-stack,"",%progbits
.text; .globl __compcert_i64_sdiv; .align 16; __compcert_i64_sdiv:
        pushl %ebp
        pushl %esi
        pushl %edi
        movl 20(%esp), %esi
        movl %esi, %ebp
        testl %esi, %esi
        jge 1f
        negl 16(%esp)
        adcl $0, %esi
        negl %esi
        movl %esi, 20(%esp)
1: movl 28(%esp), %esi
        xorl %esi, %ebp
        testl %esi, %esi
        jge 2f
        negl 24(%esp)
        adcl $0, %esi
        negl %esi
        movl %esi, 28(%esp)
2: call __compcert_i64_udivmod
        testl %ebp, %ebp
        jge 3f
        negl %esi
        adcl $0, %edi
        negl %edi
3: movl %esi, %eax
        movl %edi, %edx
        popl %edi
        popl %esi
        popl %ebp
        ret
.type __compcert_i64_sdiv, @function; .size __compcert_i64_sdiv, . - __compcert_i64_sdiv
