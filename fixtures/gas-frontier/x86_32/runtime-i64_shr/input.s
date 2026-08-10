 .section .note.GNU-stack,"",%progbits
.text; .globl __compcert_i64_shr; .align 16; __compcert_i64_shr:
        movl 12(%esp), %ecx
        testb $32, %cl
        jne 1f
        movl 4(%esp), %eax
        movl 8(%esp), %edx
        shrdl %cl, %edx, %eax
        shrl %cl, %edx
        ret
1: movl 8(%esp), %eax
        shrl %cl, %eax
        xorl %edx, %edx
        ret
.type __compcert_i64_shr, @function; .size __compcert_i64_shr, . - __compcert_i64_shr
