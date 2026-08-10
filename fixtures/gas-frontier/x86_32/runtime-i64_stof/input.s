 .section .note.GNU-stack,"",%progbits
.text; .globl __compcert_i64_stof; .align 16; __compcert_i64_stof:
        fildll 4(%esp)
        fstps 4(%esp)
        flds 4(%esp)
        ret
.type __compcert_i64_stof, @function; .size __compcert_i64_stof, . - __compcert_i64_stof
