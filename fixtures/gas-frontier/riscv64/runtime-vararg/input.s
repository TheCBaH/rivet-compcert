 .section .note.GNU-stack,"",%progbits
.text; .balign 16; .globl __compcert_va_int32; __compcert_va_int32:
                                   # a0 = ap parameter
 ld t5, 0(a0) # t5 = pointer to next argument
 addi t5, t5, 8 # advance ap
 sd t5, 0(a0) # update ap
 lw a0, -8(t5) # load it and return it in a0
 jr ra
.type __compcert_va_int32, @function; .size __compcert_va_int32, . - __compcert_va_int32
.text; .balign 16; .globl __compcert_va_int64; __compcert_va_int64:
    # a0 = ap parameter
 ld t5, 0(a0) # t5 = pointer to next argument
 addi t5, t5, 15 # 8-align and advance by 8
 and t5, t5, -8
 sd t5, 0(a0) # update ap
 ld a0, -8(t5) # return it in a0
 jr ra
.type __compcert_va_int64, @function; .size __compcert_va_int64, . - __compcert_va_int64
.text; .balign 16; .globl __compcert_va_float64; __compcert_va_float64:
    # a0 = ap parameter
 ld t5, 0(a0) # t5 = pointer to next argument
 addi t5, t5, 15 # 8-align and advance by 8
 and t5, t5, -8
 sd t5, 0(a0) # update ap
 fld fa0, -8(t5) # return it in fa0
 jr ra
.type __compcert_va_float64, @function; .size __compcert_va_float64, . - __compcert_va_float64
.text; .balign 16; .globl __compcert_va_composite; __compcert_va_composite:
 j __compcert_va_int64
.type __compcert_va_composite, @function; .size __compcert_va_composite, . - __compcert_va_composite
