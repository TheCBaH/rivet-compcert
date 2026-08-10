 .section .note.GNU-stack,"",%progbits
.text; .globl __compcert_i64_umulh; .align 16; __compcert_i64_umulh:
        pushl %esi
        pushl %edi
 movl 12(%esp), %eax
        mull 20(%esp)
        movl %edx, %ecx
        xorl %esi, %esi
        xorl %edi, %edi
        movl 16(%esp), %eax
        mull 20(%esp)
        addl %eax, %ecx
        adcl %edx, %esi
 adcl $0, %edi
        movl 24(%esp), %eax
        mull 12(%esp)
        addl %eax, %ecx
        adcl %edx, %esi
 adcl $0, %edi
        movl 16(%esp), %eax
        mull 24(%esp)
 addl %esi, %eax
        adcl %edi, %edx
 popl %edi
 popl %esi
        ret
.type __compcert_i64_umulh, @function; .size __compcert_i64_umulh, . - __compcert_i64_umulh
