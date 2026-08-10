 .section .note.GNU-stack,"",%progbits
.text; .globl __compcert_i64_sar; .align 16; __compcert_i64_sar:
        movl 12(%esp), %ecx
        testb $32, %cl
        jne 1f
        movl 4(%esp), %eax
        movl 8(%esp), %edx
        shrdl %cl, %edx, %eax
        sarl %cl, %edx
        ret
1: movl 8(%esp), %eax
        movl %eax, %edx
        sarl %cl, %eax
        sarl $31, %edx
        ret
.type __compcert_i64_sar, @function; .size __compcert_i64_sar, . - __compcert_i64_sar
