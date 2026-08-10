 .section .note.GNU-stack,"",%progbits
.text; .balign 16; .globl __compcert_va_int32; __compcert_va_int32:
        ldr w1, [x0, #24]
        cbz w1, 1f
        ldr x2, [x0, #8]
        ldr w2, [x2, w1, sxtw]
        add w1, w1, #8
        str w1, [x0, #24]
        mov w0, w2
 ret
1: ldr x1, [x0, #0]
        ldr w2, [x1, #0]
        add x1, x1, #8
        str x1, [x0, #0]
        mov w0, w2
 ret
.type __compcert_va_int32, @function; .size __compcert_va_int32, . - __compcert_va_int32
.text; .balign 16; .globl __compcert_va_int64; __compcert_va_int64:
        ldr w1, [x0, #24]
        cbz w1, 1f
        ldr x2, [x0, #8]
        ldr x2, [x2, w1, sxtw]
        add w1, w1, #8
        str w1, [x0, #24]
        mov x0, x2
 ret
1: ldr x1, [x0, #0]
        ldr x2, [x1, #0]
        add x1, x1, #8
        str x1, [x0, #0]
        mov x0, x2
 ret
.type __compcert_va_int64, @function; .size __compcert_va_int64, . - __compcert_va_int64
.text; .balign 16; .globl __compcert_va_float64; __compcert_va_float64:
        ldr w1, [x0, #28]
        cbz w1, 1f
        ldr x2, [x0, #16]
        ldr d0, [x2, w1, sxtw]
        add w1, w1, #16
        str w1, [x0, #28]
 ret
1: ldr x1, [x0, #0]
        ldr d0, [x1, #0]
        add x1, x1, #8
        str x1, [x0, #0]
 ret
.type __compcert_va_float64, @function; .size __compcert_va_float64, . - __compcert_va_float64
.text; .balign 16; .globl __compcert_va_composite; __compcert_va_composite:
 b __compcert_va_int64
.type __compcert_va_composite, @function; .size __compcert_va_composite, . - __compcert_va_composite
