 .section .note.GNU-stack,"",%progbits
.text; .globl __compcert_va_int32; .align 16; __compcert_va_int32:
        movl 0(%rdi), %edx
        cmpl $48, %edx
        jae 1f
        movq 16(%rdi), %rsi
        movl 0(%rsi, %rdx, 1), %eax
        addl $8, %edx
        movl %edx, 0(%rdi)
        ret
1: movq 8(%rdi), %rsi
        movq 0(%rsi), %rax
        addq $8, %rsi
        movq %rsi, 8(%rdi)
        ret
.type __compcert_va_int32, @function; .size __compcert_va_int32, . - __compcert_va_int32
.text; .globl __compcert_va_int64; .align 16; __compcert_va_int64:
        movl 0(%rdi), %edx
        cmpl $48, %edx
        jae 1f
        movq 16(%rdi), %rsi
        movq 0(%rsi, %rdx, 1), %rax
        addl $8, %edx
        movl %edx, 0(%rdi)
        ret
1: movq 8(%rdi), %rsi
        movq 0(%rsi), %rax
        addq $8, %rsi
        movq %rsi, 8(%rdi)
        ret
.type __compcert_va_int64, @function; .size __compcert_va_int64, . - __compcert_va_int64
.text; .globl __compcert_va_float64; .align 16; __compcert_va_float64:
        movl 4(%rdi), %edx
        cmpl $176, %edx
        jae 1f
        movq 16(%rdi), %rsi
        movsd 0(%rsi, %rdx, 1), %xmm0
        addl $16, %edx
        movl %edx, 4(%rdi)
        ret
1: movq 8(%rdi), %rsi
        movsd 0(%rsi), %xmm0
        addq $8, %rsi
        movq %rsi, 8(%rdi)
        ret
.type __compcert_va_float64, @function; .size __compcert_va_float64, . - __compcert_va_float64
.text; .globl __compcert_va_composite; .align 16; __compcert_va_composite:
        jmp __compcert_va_int64
.type __compcert_va_composite, @function; .size __compcert_va_composite, . - __compcert_va_composite
.text; .globl __compcert_va_saveregs; .align 16; __compcert_va_saveregs:
        movq %rdi, 0(%r10)
        movq %rsi, 8(%r10)
        movq %rdx, 16(%r10)
        movq %rcx, 24(%r10)
        movq %r8, 32(%r10)
        movq %r9, 40(%r10)
        testb %al, %al
        je 1f
        movaps %xmm0, 48(%r10)
        movaps %xmm1, 64(%r10)
        movaps %xmm2, 80(%r10)
        movaps %xmm3, 96(%r10)
        movaps %xmm4, 112(%r10)
        movaps %xmm5, 128(%r10)
        movaps %xmm6, 144(%r10)
        movaps %xmm7, 160(%r10)
1: ret
.type __compcert_va_saveregs, @function; .size __compcert_va_saveregs, . - __compcert_va_saveregs
