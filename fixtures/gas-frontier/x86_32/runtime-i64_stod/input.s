 .section .note.GNU-stack,"",%progbits
.text; .globl __compcert_i64_stod; .align 16; __compcert_i64_stod:
        fildll 4(%esp)
        ret
.type __compcert_i64_stod, @function; .size __compcert_i64_stod, . - __compcert_i64_stod
