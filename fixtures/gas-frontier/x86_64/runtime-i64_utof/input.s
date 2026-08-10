 .section .note.GNU-stack,"",%progbits
.text; .globl __compcert_i64_utof; .align 16; __compcert_i64_utof:
        testq %rdi, %rdi
        js 1f
        pxor %xmm0, %xmm0
        cvtsi2ssq %rdi, %xmm0
        ret
1:
        movq %rdi, %rax
        shrq %rax
        andq $1, %rdi
        orq %rdi, %rax
        pxor %xmm0, %xmm0
        cvtsi2ssq %rax, %xmm0
        addss %xmm0, %xmm0
        ret
.type __compcert_i64_utof, @function; .size __compcert_i64_utof, . - __compcert_i64_utof
