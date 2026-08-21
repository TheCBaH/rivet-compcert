 .section .note.GNU-stack,"",%progbits
.text; .globl __compcert_i64_udivmod; .align 16; __compcert_i64_udivmod:
        cmpl $0, 32(%esp)
        jne 1f
        movl 28(%esp), %ecx
        movl 24(%esp), %eax
        xorl %edx, %edx
        divl %ecx
        movl %eax, %edi
        movl 20(%esp), %eax
        divl %ecx
        movl %eax, %esi
        movl %edx, %eax
        xorl %edx, %edx
        ret
1: movl 28(%esp), %ecx
        movl 32(%esp), %esi
        movl 20(%esp), %eax
        movl 24(%esp), %edx
2: shrl $1, %esi
        rcrl $1, %ecx
        shrl $1, %edx
        rcrl $1, %eax
        testl %esi, %esi
        jnz 2b
        divl %ecx
        movl %eax, %esi
3: movl 32(%esp), %ecx
        imull %esi, %ecx
        movl 28(%esp), %eax
        mull %esi
        add %ecx, %edx
        jc 5f
        movl %eax, %ecx
        movl 20(%esp), %eax
        subl %ecx, %eax
        movl %edx, %ecx
        movl 24(%esp), %edx
        sbbl %ecx, %edx
        jnc 4f
        decl %esi
        addl 28(%esp), %eax
        adcl 32(%esp), %edx
4: xorl %edi, %edi
        ret
5: decl %esi
        jmp 3b
.type __compcert_i64_udivmod, @function; .size __compcert_i64_udivmod, . - __compcert_i64_udivmod
