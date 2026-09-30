# sp.S for wasm64 (-sMEMORY64): the shadow stack pointer is an i64.
	.globaltype __stack_pointer, i64

	.globl	jspi_get_sp
	.type	jspi_get_sp,@function
jspi_get_sp:
	.functype	jspi_get_sp () -> (i64)
	global.get	__stack_pointer
	end_function

	.globl	jspi_set_sp
	.type	jspi_set_sp,@function
jspi_set_sp:
	.functype	jspi_set_sp (i64) -> ()
	local.get	0
	global.set	__stack_pointer
	end_function

	.functype	jspi_thread_run (i64) -> ()
	.globl	jspi_thread_entry
	.type	jspi_thread_entry,@function
	.export_name	jspi_thread_entry, jspi_thread_entry
jspi_thread_entry:
	.functype	jspi_thread_entry (i64) -> ()
	local.get	0
	i64.load	0
	global.set	__stack_pointer
	local.get	0
	call	jspi_thread_run
	end_function
