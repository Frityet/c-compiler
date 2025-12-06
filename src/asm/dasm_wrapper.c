#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>

/* Hook for DynASM extern resolution. */
static const void *dasm_wrap_externs = NULL;
static size_t dasm_wrap_extern_count = 0;

typedef struct dasm_State dasm_State;

void dasm_wrap_set_externs(const void *const *ext, size_t count)
{
	dasm_wrap_externs = (const void *)ext;
	dasm_wrap_extern_count = count;
}

/* DynASM will call this through DASM_EXTERN. */
static int dasm_wrap_resolve(dasm_State **Dst, unsigned char *pc, unsigned int sym, int rel)
{
	(void)Dst;
	if (dasm_wrap_externs == NULL || sym >= dasm_wrap_extern_count) {
		return 0;
	}
	uintptr_t target = (uintptr_t)((const void *const *)dasm_wrap_externs)[sym];
	if (rel != 0) {
		/* Relative reference (e.g., call/jmp). pc already points past opcode; adjust for disp32. */
		return (int)(ptrdiff_t)(target - (uintptr_t)(pc + 4));
	}
	return (int)(ptrdiff_t)target;
}

#define DASM_EXTERN(a, b, c, d) dasm_wrap_resolve((a), (b), (c), (d))

#include "../../extern/LuaJIT/dynasm/dasm_proto.h"
#include "../../extern/LuaJIT/dynasm/dasm_x86.h"
