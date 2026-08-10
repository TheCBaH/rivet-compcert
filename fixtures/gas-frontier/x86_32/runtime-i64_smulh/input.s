 .section .note.GNU-stack,"",%progbits
.text; .globl __compcert_i64_smulh; .align 16; __compcert_i64_smulh:
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
 addl %eax, %esi
        adcl %edx, %edi
        xorl %eax, %eax
        xorl %edx, %edx
        cmpl $0, 16(%esp)
        cmovl 20(%esp), %eax
        cmovl 24(%esp), %edx
        subl %eax, %esi
        sbbl %edx, %edi
        xorl %eax, %eax
        xorl %edx, %edx
        cmpl $0, 24(%esp)
        cmovl 12(%esp), %eax
        cmovl 16(%esp), %edx
        subl %eax, %esi
        sbbl %edx, %edi
        movl %esi, %eax
        movl %edi, %edx
        popl %edi
        popl %esi
        ret
.type __compcert_i64_smulh, @function; .size __compcert_i64_smulh, . - __compcert_i64_smulh
