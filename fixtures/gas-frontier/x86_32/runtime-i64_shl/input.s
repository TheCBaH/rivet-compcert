 .section .note.GNU-stack,"",%progbits
.text; .globl __compcert_i64_shl; .align 16; __compcert_i64_shl:
        movl 12(%esp), %ecx
        testb $32, %cl
        jne 1f
        movl 4(%esp), %eax
        movl 8(%esp), %edx
        shldl %cl, %eax, %edx
        shll %cl, %eax
        ret
1: movl 4(%esp), %edx
        shll %cl, %edx
        xorl %eax, %eax
        ret
.type __compcert_i64_shl, @function; .size __compcert_i64_shl, . - __compcert_i64_shl
