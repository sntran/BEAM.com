# The shadow stack pointer of the running green thread (see jspi_pthread.c).
	.globaltype __stack_pointer, i32

	.globl	jspi_get_sp
	.type	jspi_get_sp,@function
jspi_get_sp:
	.functype	jspi_get_sp () -> (i32)
	global.get	__stack_pointer
	end_function

	.globl	jspi_set_sp
	.type	jspi_set_sp,@function
jspi_set_sp:
	.functype	jspi_set_sp (i32) -> ()
	local.get	0
	global.set	__stack_pointer
	end_function

# The entry of a green thread: switch to its own shadow stack before any C
# code runs (a C function can put its frame on the shadow stack first,
# which is the stack of another thread here). t is a struct __pthread *,
# whose first word is the top of its stack.
	.functype	jspi_thread_run (i32) -> ()
	.globl	jspi_thread_entry
	.type	jspi_thread_entry,@function
	.export_name	jspi_thread_entry, jspi_thread_entry
jspi_thread_entry:
	.functype	jspi_thread_entry (i32) -> ()
	local.get	0
	i32.load	0
	global.set	__stack_pointer
	local.get	0
	call	jspi_thread_run
	end_function
