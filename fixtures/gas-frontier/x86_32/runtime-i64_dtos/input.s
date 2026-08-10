 .section .note.GNU-stack,"",%progbits
.text; .globl __compcert_i64_dtos; .align 16; __compcert_i64_dtos:
        subl $4, %esp
        fnstcw 0(%esp)
        movw 0(%esp), %ax
        movb $12, %ah
        movw %ax, 2(%esp)
        fldcw 2(%esp)
        fldl 8(%esp)
        fistpll 8(%esp)
        fldcw 0(%esp)
        movl 8(%esp), %eax
        movl 12(%esp), %edx
        addl $4, %esp
        ret
.type __compcert_i64_dtos, @function; .size __compcert_i64_dtos, . - __compcert_i64_dtos
