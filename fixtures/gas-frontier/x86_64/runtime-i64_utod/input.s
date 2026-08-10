 .section .note.GNU-stack,"",%progbits
.text; .globl __compcert_i64_utod; .align 16; __compcert_i64_utod:
        testq %rdi, %rdi
        js 1f
        pxor %xmm0, %xmm0
        cvtsi2sdq %rdi, %xmm0
        ret
1:
        movq %rdi, %rax
        shrq %rax
        andq $1, %rdi
        orq %rdi, %rax
        pxor %xmm0, %xmm0
        cvtsi2sdq %rax, %xmm0
        addsd %xmm0, %xmm0
        ret
.type __compcert_i64_utod, @function; .size __compcert_i64_utod, . - __compcert_i64_utod
