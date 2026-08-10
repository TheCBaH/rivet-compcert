 .section .note.GNU-stack,"",%progbits
.text; .globl __compcert_va_int32; .align 16; __compcert_va_int32:
        movl 4(%esp), %ecx
        movl 0(%ecx), %edx
        movl 0(%edx), %eax
        addl $4, %edx
        movl %edx, 0(%ecx)
        ret
.type __compcert_va_int32, @function; .size __compcert_va_int32, . - __compcert_va_int32
.text; .globl __compcert_va_int64; .align 16; __compcert_va_int64:
        movl 4(%esp), %ecx
        movl 0(%ecx), %edx
        movl 0(%edx), %eax
 movl 4(%edx), %edx
        addl $8, 0(%ecx)
        ret
.type __compcert_va_int64, @function; .size __compcert_va_int64, . - __compcert_va_int64
.text; .globl __compcert_va_float64; .align 16; __compcert_va_float64:
        movl 4(%esp), %ecx
        movl 0(%ecx), %edx
        fldl 0(%edx)
        addl $8, %edx
        movl %edx, 0(%ecx)
        ret
.type __compcert_va_float64, @function; .size __compcert_va_float64, . - __compcert_va_float64
.text; .globl __compcert_va_composite; .align 16; __compcert_va_composite:
        movl 4(%esp), %ecx
 movl 8(%esp), %edx
        movl 0(%ecx), %eax
 leal 3(%eax, %edx), %edx
        andl $0xfffffffc, %edx
        movl %edx, 0(%ecx)
        ret
.type __compcert_va_composite, @function; .size __compcert_va_composite, . - __compcert_va_composite
