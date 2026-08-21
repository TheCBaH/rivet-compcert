 .section .note.GNU-stack,"",%progbits
.text; .globl __compcert_i64_smod; .align 16; __compcert_i64_smod:
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
        testl %esi, %esi
        jge 2f
        negl 24(%esp)
        adcl $0, %esi
        negl %esi
        movl %esi, 28(%esp)
2: call __compcert_i64_udivmod
        testl %ebp, %ebp
        jge 3f
        negl %eax
        adcl $0, %edx
        negl %edx
3: popl %edi
        popl %esi
        popl %ebp
        ret
.type __compcert_i64_smod, @function; .size __compcert_i64_smod, . - __compcert_i64_smod
