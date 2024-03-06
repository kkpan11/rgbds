/* SPDX-License-Identifier: MIT */

%code requires {
	#include <stdint.h>
	#include <inttypes.h>
	#include <string>
	#include <variant>
	#include <vector>

	#include "asm/format.hpp"
	#include "asm/lexer.hpp"
	#include "asm/macro.hpp"
	#include "asm/rpn.hpp"
	#include "asm/symbol.hpp"

	#include "linkdefs.hpp"

	struct AlignmentSpec {
		uint8_t alignment;
		uint16_t alignOfs;
	};

	struct ForArgs {
		int32_t start;
		int32_t stop;
		int32_t step;
	};

	struct StrFmtArgList {
		std::string *format;
		std::vector<std::variant<uint32_t, std::string>> *args;
	};
}
%code {
	#include <ctype.h>
	#include <errno.h>
	#include <new>
	#include <stdio.h>
	#include <stdlib.h>
	#include <string.h>

	#include "asm/charmap.hpp"
	#include "asm/fixpoint.hpp"
	#include "asm/fstack.hpp"
	#include "asm/main.hpp"
	#include "asm/opt.hpp"
	#include "asm/output.hpp"
	#include "asm/section.hpp"
	#include "util.hpp"
	#include "asm/warning.hpp"

	#include "extern/utf8decoder.hpp"

	#include "helpers.hpp"

	static CaptureBody captureBody; // Captures a REPT/FOR or MACRO

	static void upperstring(char *dest, char const *src);
	static void lowerstring(char *dest, char const *src);
	static uint32_t str2int2(std::vector<uint8_t> const &s);
	static const char *strrstr(char const *s1, char const *s2);
	static void errorInvalidUTF8Byte(uint8_t byte, char const *functionName);
	static size_t strlenUTF8(char const *s);
	static void strsubUTF8(char *dest, size_t destLen, char const *src, uint32_t pos, uint32_t len);
	static size_t charlenUTF8(char const *str);
	static void charsubUTF8(char *dest, char const *src, uint32_t pos);
	static uint32_t adjustNegativePos(int32_t pos, size_t len, char const *functionName);
	static void strrpl(
	    char *dest, size_t destLen, char const *src, char const *old, char const *rep
	);
	static void initStrFmtArgList(StrFmtArgList & args);
	static void freeStrFmtArgList(StrFmtArgList & args);
	static void strfmt(
	    char *dest, size_t destLen, char const *spec,
	    std::vector<std::variant<uint32_t, std::string>> &args
	);
	static void compoundAssignment(const char *symName, enum RPNCommand op, int32_t constValue);
	static void initDsArgList(std::vector<Expression> * &args);
	static void initPurgeArgList(std::vector<std::string> * &args);
	static void failAssert(enum AssertionType type);
	static void failAssertMsg(enum AssertionType type, char const *msg);
	void yyerror(char const *str);

	// The CPU encodes instructions in a logical way, so most instructions actually follow patterns.
	// These enums thus help with bit twiddling to compute opcodes
	enum { REG_B = 0, REG_C, REG_D, REG_E, REG_H, REG_L, REG_HL_IND, REG_A };

	enum {
		REG_BC_IND = 0,
		REG_DE_IND,
		REG_HL_INDINC,
		REG_HL_INDDEC,
	};

	enum {
		REG_BC = 0,
		REG_DE = 1,
		REG_HL = 2,
		// LD/INC/ADD/DEC allow SP, PUSH/POP allow AF
		REG_SP = 3,
		REG_AF = 3
	};

	enum { CC_NZ = 0, CC_Z, CC_NC, CC_C };
}

%union
{
	char symName[MAXSYMLEN + 1];
	char string[MAXSTRLEN + 1];
	Expression expr;
	int32_t constValue;
	enum RPNCommand compoundEqual;
	enum SectionModifier sectMod;
	SectionSpec sectSpec;
	MacroArgs *macroArg;
	enum AssertionType assertType;
	AlignmentSpec alignSpec;
	std::vector<Expression> *dsArgs;
	std::vector<std::string> *purgeArgs;
	ForArgs forArgs;
	StrFmtArgList strfmtArgs;
	bool captureTerminated;
}

%type <expr> relocexpr
%type <expr> relocexpr_no_str
%type <constValue> const
%type <constValue> const_no_str
%type <constValue> const_8bit
%type <constValue> uconst
%type <constValue> rs_uconst
%type <constValue> const_3bit
%type <expr> reloc_8bit
%type <expr> reloc_8bit_no_str
%type <expr> reloc_8bit_offset
%type <expr> reloc_16bit
%type <expr> reloc_16bit_no_str
%type <constValue> sectiontype

%type <string> string
%type <string> strcat_args
%type <strfmtArgs> strfmt_args
%type <strfmtArgs> strfmt_va_args

%type <constValue> sectorg
%type <sectSpec> sectattrs

%token <constValue> T_NUMBER "number"
%token <string> T_STRING "string"

%token T_PERIOD "."
%token T_COMMA ","
%token T_COLON ":" T_DOUBLE_COLON "::"
%token T_LBRACK "[" T_RBRACK "]"
%token T_LPAREN "(" T_RPAREN ")"
%token T_NEWLINE "newline"

%token T_OP_LOGICNOT "!"
%token T_OP_LOGICAND "&&" T_OP_LOGICOR "||"
%token T_OP_LOGICGT ">" T_OP_LOGICLT "<"
%token T_OP_LOGICGE ">=" T_OP_LOGICLE "<="
%token T_OP_LOGICNE "!=" T_OP_LOGICEQU "=="
%token T_OP_ADD "+" T_OP_SUB "-"
%token T_OP_OR "|" T_OP_XOR "^" T_OP_AND "&"
%token T_OP_SHL "<<" T_OP_SHR ">>" T_OP_USHR ">>>"
%token T_OP_MUL "*" T_OP_DIV "/" T_OP_MOD "%"
%token T_OP_NOT "~"
%left T_OP_LOGICOR
%left T_OP_LOGICAND
%left T_OP_LOGICGT T_OP_LOGICLT T_OP_LOGICGE T_OP_LOGICLE T_OP_LOGICNE T_OP_LOGICEQU
%left T_OP_ADD T_OP_SUB
%left T_OP_OR T_OP_XOR T_OP_AND
%left T_OP_SHL T_OP_SHR T_OP_USHR
%left T_OP_MUL T_OP_DIV T_OP_MOD

%precedence NEG // negation -- unary minus

%token T_OP_EXP "**"
%left T_OP_EXP

%token T_OP_DEF "DEF"
%token T_OP_BANK "BANK"
%token T_OP_ALIGN "ALIGN"
%token T_OP_SIZEOF "SIZEOF" T_OP_STARTOF "STARTOF"

%token T_OP_SIN "SIN" T_OP_COS "COS" T_OP_TAN "TAN"
%token T_OP_ASIN "ASIN" T_OP_ACOS "ACOS" T_OP_ATAN "ATAN" T_OP_ATAN2 "ATAN2"
%token T_OP_FDIV "FDIV"
%token T_OP_FMUL "FMUL"
%token T_OP_FMOD "FMOD"
%token T_OP_POW "POW"
%token T_OP_LOG "LOG"
%token T_OP_ROUND "ROUND"
%token T_OP_CEIL "CEIL" T_OP_FLOOR "FLOOR"
%type <constValue> opt_q_arg

%token T_OP_HIGH "HIGH" T_OP_LOW "LOW"
%token T_OP_ISCONST "ISCONST"

%token T_OP_STRCMP "STRCMP"
%token T_OP_STRIN "STRIN" T_OP_STRRIN "STRRIN"
%token T_OP_STRSUB "STRSUB"
%token T_OP_STRLEN "STRLEN"
%token T_OP_STRCAT "STRCAT"
%token T_OP_STRUPR "STRUPR" T_OP_STRLWR "STRLWR"
%token T_OP_STRRPL "STRRPL"
%token T_OP_STRFMT "STRFMT"

%token T_OP_CHARLEN "CHARLEN"
%token T_OP_CHARSUB "CHARSUB"
%token T_OP_INCHARMAP "INCHARMAP"

%token <symName> T_LABEL "label"
%token <symName> T_ID "identifier"
%token <symName> T_LOCAL_ID "local identifier"
%token <symName> T_ANON "anonymous label"
%type <symName> def_id
%type <symName> redef_id
%type <symName> scoped_id
%type <symName> scoped_anon_id
%token T_POP_EQU "EQU"
%token T_POP_EQUAL "="
%token T_POP_EQUS "EQUS"

%token T_POP_ADDEQ "+=" T_POP_SUBEQ "-="
%token T_POP_MULEQ "*=" T_POP_DIVEQ "/=" T_POP_MODEQ "%="
%token T_POP_OREQ "|=" T_POP_XOREQ "^=" T_POP_ANDEQ "&="
%token T_POP_SHLEQ "<<=" T_POP_SHREQ ">>="
%type <compoundEqual> compoundeq

%token T_POP_INCLUDE "INCLUDE"
%token T_POP_PRINT "PRINT" T_POP_PRINTLN "PRINTLN"
%token T_POP_IF "IF" T_POP_ELIF "ELIF" T_POP_ELSE "ELSE" T_POP_ENDC "ENDC"
%token T_POP_EXPORT "EXPORT"
%token T_POP_DB "DB" T_POP_DS "DS" T_POP_DW "DW" T_POP_DL "DL"
%token T_POP_SECTION "SECTION" T_POP_FRAGMENT "FRAGMENT"
%token T_POP_ENDSECTION "ENDSECTION"
%token T_POP_RB "RB" T_POP_RW "RW" // There is no T_POP_RL, only T_Z80_RL
%token T_POP_MACRO "MACRO"
%token T_POP_ENDM "ENDM"
%token T_POP_RSRESET "RSRESET" T_POP_RSSET "RSSET"
%token T_POP_UNION "UNION" T_POP_NEXTU "NEXTU" T_POP_ENDU "ENDU"
%token T_POP_INCBIN "INCBIN" T_POP_REPT "REPT" T_POP_FOR "FOR"
%token T_POP_CHARMAP "CHARMAP"
%token T_POP_NEWCHARMAP "NEWCHARMAP"
%token T_POP_SETCHARMAP "SETCHARMAP"
%token T_POP_PUSHC "PUSHC"
%token T_POP_POPC "POPC"
%token T_POP_SHIFT "SHIFT"
%token T_POP_ENDR "ENDR"
%token T_POP_BREAK "BREAK"
%token T_POP_LOAD "LOAD" T_POP_ENDL "ENDL"
%token T_POP_FAIL "FAIL"
%token T_POP_WARN "WARN"
%token T_POP_FATAL "FATAL"
%token T_POP_ASSERT "ASSERT" T_POP_STATIC_ASSERT "STATIC_ASSERT"
%token T_POP_PURGE "PURGE"
%token T_POP_REDEF "REDEF"
%token T_POP_POPS "POPS"
%token T_POP_PUSHS "PUSHS"
%token T_POP_POPO "POPO"
%token T_POP_PUSHO "PUSHO"
%token T_POP_OPT "OPT"
%token T_SECT_ROM0 "ROM0" T_SECT_ROMX "ROMX"
%token T_SECT_WRAM0 "WRAM0" T_SECT_WRAMX "WRAMX" T_SECT_HRAM "HRAM"
%token T_SECT_VRAM "VRAM" T_SECT_SRAM "SRAM" T_SECT_OAM "OAM"

%type <captureTerminated> capture_rept
%type <captureTerminated> capture_macro

%type <sectMod> sectmod
%type <macroArg> macroargs

%type <alignSpec> align_spec

%type <dsArgs> ds_args
%type <purgeArgs> purge_args
%type <forArgs> for_args

%token T_Z80_ADC "adc" T_Z80_ADD "add" T_Z80_AND "and"
%token T_Z80_BIT "bit"
%token T_Z80_CALL "call" T_Z80_CCF "ccf" T_Z80_CP "cp" T_Z80_CPL "cpl"
%token T_Z80_DAA "daa" T_Z80_DEC "dec" T_Z80_DI "di"
%token T_Z80_EI "ei"
%token T_Z80_HALT "halt"
%token T_Z80_INC "inc"
%token T_Z80_JP "jp" T_Z80_JR "jr"
%token T_Z80_LD "ld"
%token T_Z80_LDI "ldi"
%token T_Z80_LDD "ldd"
%token T_Z80_LDH "ldh"
%token T_Z80_NOP "nop"
%token T_Z80_OR "or"
%token T_Z80_POP "pop" T_Z80_PUSH "push"
%token T_Z80_RES "res" T_Z80_RET "ret" T_Z80_RETI "reti" T_Z80_RST "rst"
%token T_Z80_RL "rl" T_Z80_RLA "rla" T_Z80_RLC "rlc" T_Z80_RLCA "rlca"
%token T_Z80_RR "rr" T_Z80_RRA "rra" T_Z80_RRC "rrc" T_Z80_RRCA "rrca"
%token T_Z80_SBC "sbc" T_Z80_SCF "scf" T_Z80_SET "set" T_Z80_STOP "stop"
%token T_Z80_SLA "sla" T_Z80_SRA "sra" T_Z80_SRL "srl" T_Z80_SUB "sub"
%token T_Z80_SWAP "swap"
%token T_Z80_XOR "xor"

%token T_TOKEN_A "a"
%token T_TOKEN_B "b" T_TOKEN_C "c"
%token T_TOKEN_D "d" T_TOKEN_E "e"
%token T_TOKEN_H "h" T_TOKEN_L "l"
%token T_MODE_AF "af" T_MODE_BC "bc" T_MODE_DE "de" T_MODE_SP "sp"
%token T_MODE_HL "hl" T_MODE_HL_DEC "hld/hl-" T_MODE_HL_INC "hli/hl+"
%token T_CC_NZ "nz" T_CC_Z "z" T_CC_NC "nc" // There is no T_CC_C, only T_TOKEN_C

%type <constValue> reg_r
%type <constValue> reg_ss
%type <constValue> reg_rr
%type <constValue> reg_tt
%type <constValue> ccode_expr
%type <constValue> ccode
%type <expr> op_a_n
%type <constValue> op_a_r
%type <expr> op_mem_ind
%type <assertType> assert_type

%token T_EOB "end of buffer"
%token T_EOF 0 "end of file"
%start asmfile

%%

// Assembly files.

asmfile: lines
;

lines:
	  %empty
	| lines opt_diff_mark line
;

endofline: T_NEWLINE | T_EOB
;

opt_diff_mark:
	  %empty // OK
	| T_OP_ADD {
		error(
			"syntax error, unexpected + at the beginning of the line (is it a leftover diff mark?)\n"
		);
	}
	| T_OP_SUB {
		error(
			"syntax error, unexpected - at the beginning of the line (is it a leftover diff mark?)\n"
		);
	}
;

// Lines and line directives.

line:
	  plain_directive endofline
	| line_directive // Directives that manage newlines themselves
	// Continue parsing the next line on a syntax error
	| error {
		lexer_SetMode(LEXER_NORMAL);
		lexer_ToggleStringExpansion(true);
	} endofline {
		fstk_StopRept();
		yyerrok;
	}
	// Hint about unindented macros parsed as labels
	| T_LABEL error {
		lexer_SetMode(LEXER_NORMAL);
		lexer_ToggleStringExpansion(true);
	} endofline {
		Symbol *macro = sym_FindExactSymbol($1);

		if (macro && macro->type == SYM_MACRO)
		fprintf(
			stderr,
			"    To invoke `%s` as a macro it must be indented\n",
			$1
		);
		fstk_StopRept();
		yyerrok;
	}
;

// For "logistical" reasons, these directives must manage newlines themselves.
// This is because we need to switch the lexer's mode *after* the newline has been read,
// and to avoid causing some grammar conflicts (token reducing is finicky).
// This is DEFINITELY one of the more FRAGILE parts of the codebase, handle with care.
line_directive:
	  macrodef
	| rept
	| for
	| break
	| include
	| if
	// It's important that all of these require being at line start for `skipIfBlock`
	| elif
	| else
;

if:
	T_POP_IF const T_NEWLINE {
		lexer_IncIFDepth();

		if ($2)
			lexer_RunIFBlock();
		else
			lexer_SetMode(LEXER_SKIP_TO_ELIF);
	}
;

elif:
	T_POP_ELIF const T_NEWLINE {
		if (lexer_GetIFDepth() == 0)
			fatalerror("Found ELIF outside an IF construct\n");

		if (lexer_RanIFBlock()) {
			if (lexer_ReachedELSEBlock())
				fatalerror("Found ELIF after an ELSE block\n");

			lexer_SetMode(LEXER_SKIP_TO_ENDC);
		} else if ($2) {
			lexer_RunIFBlock();
		} else {
			lexer_SetMode(LEXER_SKIP_TO_ELIF);
		}
	}
;

else:
	T_POP_ELSE T_NEWLINE {
		if (lexer_GetIFDepth() == 0)
			fatalerror("Found ELSE outside an IF construct\n");

		if (lexer_RanIFBlock()) {
			if (lexer_ReachedELSEBlock())
				fatalerror("Found ELSE after an ELSE block\n");

			lexer_SetMode(LEXER_SKIP_TO_ENDC);
		} else {
			lexer_RunIFBlock();
			lexer_ReachELSEBlock();
		}
	}
;

// Directives, labels, functions, and values.

plain_directive:
	  label
	| label cpu_commands
	| label macro
	| label directive
	| assignment_directive
;

endc:
	T_POP_ENDC {
		lexer_DecIFDepth();
	}
;

def_id:
	T_OP_DEF {
		lexer_ToggleStringExpansion(false);
	} T_ID {
		lexer_ToggleStringExpansion(true);
		strcpy($$, $3);
	}
;

redef_id:
	T_POP_REDEF {
		lexer_ToggleStringExpansion(false);
	} T_ID {
		lexer_ToggleStringExpansion(true);
		strcpy($$, $3);
	}
;

// T_LABEL covers identifiers followed by a double colon (e.g. `call Function::ret`,
// to be read as `call Function :: ret`). This should not conflict with anything.
scoped_id: T_ID | T_LOCAL_ID | T_LABEL;
scoped_anon_id: scoped_id | T_ANON;

label:
	  %empty
	| T_COLON {
		sym_AddAnonLabel();
	}
	| T_LOCAL_ID {
		sym_AddLocalLabel($1);
	}
	| T_LOCAL_ID T_COLON {
		sym_AddLocalLabel($1);
	}
	| T_LABEL T_COLON {
		sym_AddLabel($1);
	}
	| T_LOCAL_ID T_DOUBLE_COLON {
		sym_AddLocalLabel($1);
		sym_Export($1);
	}
	| T_LABEL T_DOUBLE_COLON {
		sym_AddLabel($1);
		sym_Export($1);
	}
;

macro:
	T_ID {
		// Parsing 'macroargs' will restore the lexer's normal mode
		lexer_SetMode(LEXER_RAW);
	} macroargs {
		fstk_RunMacro($1, *$3);
	}
;

macroargs:
	%empty {
		$$ = new(std::nothrow) MacroArgs();
		if (!$$)
			fatalerror("Failed to allocate memory for macro arguments: %s\n", strerror(errno));
	}
	| macroargs T_STRING {
		$1->append($2);
		$$ = $1;
	}
;

// These commands start with a T_LABEL.
assignment_directive: equ | assignment | rb | rw | rl | equs;

directive:
	  endc
	| print
	| println
	| export
	| db
	| dw
	| dl
	| ds
	| section
	| rsreset
	| rsset
	| union
	| nextu
	| endu
	| incbin
	| charmap
	| newcharmap
	| setcharmap
	| pushc
	| popc
	| load
	| shift
	| fail
	| warn
	| assert
	| def_equ
	| redef_equ
	| def_set
	| def_rb
	| def_rw
	| def_rl
	| def_equs
	| redef_equs
	| purge
	| pops
	| pushs
	| endsection
	| popo
	| pusho
	| opt
	| align
;

trailing_comma: %empty | T_COMMA;

compoundeq:
	T_POP_ADDEQ {
		$$ = RPN_ADD;
	}
	| T_POP_SUBEQ {
		$$ = RPN_SUB;
	}
	| T_POP_MULEQ {
		$$ = RPN_MUL;
	}
	| T_POP_DIVEQ {
		$$ = RPN_DIV;
	}
	| T_POP_MODEQ {
		$$ = RPN_MOD;
	}
	| T_POP_XOREQ {
		$$ = RPN_XOR;
	}
	| T_POP_OREQ {
		$$ = RPN_OR;
	}
	| T_POP_ANDEQ {
		$$ = RPN_AND;
	}
	| T_POP_SHLEQ {
		$$ = RPN_SHL;
	}
	| T_POP_SHREQ {
		$$ = RPN_SHR;
	}
;

equ:
	T_LABEL T_POP_EQU const {
		warning(WARNING_OBSOLETE, "`%s EQU` is deprecated; use `DEF %s EQU`\n", $1, $1);
		sym_AddEqu($1, $3);
	}
;

assignment:
	T_LABEL T_POP_EQUAL const {
		warning(WARNING_OBSOLETE, "`%s =` is deprecated; use `DEF %s =`\n", $1, $1);
		sym_AddVar($1, $3);
	}
	| T_LABEL compoundeq const {
		const char *compoundEqOperator = nullptr;
		switch ($2) {
			case RPN_ADD: compoundEqOperator = "+="; break;
			case RPN_SUB: compoundEqOperator = "-="; break;
			case RPN_MUL: compoundEqOperator = "*="; break;
			case RPN_DIV: compoundEqOperator = "/="; break;
			case RPN_MOD: compoundEqOperator = "%="; break;
			case RPN_XOR: compoundEqOperator = "^="; break;
			case RPN_OR:  compoundEqOperator = "|="; break;
			case RPN_AND: compoundEqOperator = "&="; break;
			case RPN_SHL: compoundEqOperator = "<<="; break;
			case RPN_SHR: compoundEqOperator = ">>="; break;
			default: break;
		}

		warning(
			WARNING_OBSOLETE,
			"`%s %s` is deprecated; use `DEF %s %s`\n",
			$1,
			compoundEqOperator,
			$1,
			compoundEqOperator
		);
		compoundAssignment($1, $2, $3);
	}
;

equs:
	T_LABEL T_POP_EQUS string {
		warning(WARNING_OBSOLETE, "`%s EQUS` is deprecated; use `DEF %s EQUS`\n", $1, $1);
		sym_AddString($1, $3);
	}
;

rb:
	T_LABEL T_POP_RB rs_uconst {
		warning(WARNING_OBSOLETE, "`%s RB` is deprecated; use `DEF %s RB`\n", $1, $1);
		sym_AddEqu($1, sym_GetConstantValue("_RS"));
		sym_AddVar("_RS", sym_GetConstantValue("_RS") + $3);
	}
;

rw:
	T_LABEL T_POP_RW rs_uconst {
		warning(WARNING_OBSOLETE, "`%s RW` is deprecated; use `DEF %s RW`\n", $1, $1);
		sym_AddEqu($1, sym_GetConstantValue("_RS"));
		sym_AddVar("_RS", sym_GetConstantValue("_RS") + 2 * $3);
	}
;

rl:
	T_LABEL T_Z80_RL rs_uconst {
		warning(WARNING_OBSOLETE, "`%s RL` is deprecated; use `DEF %s RL`\n", $1, $1);
		sym_AddEqu($1, sym_GetConstantValue("_RS"));
		sym_AddVar("_RS", sym_GetConstantValue("_RS") + 4 * $3);
	}
;

align:
	T_OP_ALIGN align_spec {
		sect_AlignPC($2.alignment, $2.alignOfs);
	}
;

align_spec:
	uconst {
		if ($1 > 16) {
			error("Alignment must be between 0 and 16, not %u\n", $1);
			$$.alignment = $$.alignOfs = 0;
		} else {
			$$.alignment = $1;
			$$.alignOfs = 0;
		}
	}
	| uconst T_COMMA const {
		if ($1 > 16) {
			error("Alignment must be between 0 and 16, not %u\n", $1);
			$$.alignment = $$.alignOfs = 0;
		} else if ($3 <= -(1 << $1) || $3 >= 1 << $1) {
			error(
				"The absolute alignment offset (%" PRIu32 ") must be less than alignment size (%d)\n",
				(uint32_t)($3 < 0 ? -$3 : $3),
				1 << $1
			);
			$$.alignment = $$.alignOfs = 0;
		} else {
			$$.alignment = $1;
			$$.alignOfs = $3 < 0 ? (1 << $1) + $3 : $3;
		}
	}
;

opt:
	T_POP_OPT {
		// Parsing 'opt_list' will restore the lexer's normal mode
		lexer_SetMode(LEXER_RAW);
	} opt_list
;

opt_list:
	  opt_list_entry
	| opt_list opt_list_entry
;

opt_list_entry:
	T_STRING {
		opt_Parse($1);
	}
;

popo:
	T_POP_POPO {
		opt_Pop();
	}
;

pusho:
	T_POP_PUSHO {
		opt_Push();
	}
;

pops:
	T_POP_POPS {
		sect_PopSection();
	}
;

pushs:
	T_POP_PUSHS {
		sect_PushSection();
	}
;

endsection:
	T_POP_ENDSECTION {
		sect_EndSection();
	}
;

fail:
	T_POP_FAIL string {
		fatalerror("%s\n", $2);
	}
;

warn:
	T_POP_WARN string {
		warning(WARNING_USER, "%s\n", $2);
	}
;

assert_type:
	%empty {
		$$ = ASSERT_ERROR;
	}
	| T_POP_WARN T_COMMA {
		$$ = ASSERT_WARN;
	}
	| T_POP_FAIL T_COMMA {
		$$ = ASSERT_ERROR;
	}
	| T_POP_FATAL T_COMMA {
		$$ = ASSERT_FATAL;
	}
;

assert:
	T_POP_ASSERT assert_type relocexpr {
		if (!$3.isKnown) {
			out_CreateAssert($2, $3, "", sect_GetOutputOffset());
		} else if ($3.val == 0) {
			failAssert($2);
		}
		rpn_Free($3);
	}
	| T_POP_ASSERT assert_type relocexpr T_COMMA string {
		if (!$3.isKnown) {
			out_CreateAssert($2, $3, $5, sect_GetOutputOffset());
		} else if ($3.val == 0) {
			failAssertMsg($2, $5);
		}
		rpn_Free($3);
	}
	| T_POP_STATIC_ASSERT assert_type const {
		if ($3 == 0)
			failAssert($2);
	}
	| T_POP_STATIC_ASSERT assert_type const T_COMMA string {
		if ($3 == 0)
			failAssertMsg($2, $5);
	}
;

shift:
	T_POP_SHIFT {
		macro_ShiftCurrentArgs(1);
	}
	| T_POP_SHIFT const {
		macro_ShiftCurrentArgs($2);
	}
;

load:
	T_POP_LOAD sectmod string T_COMMA sectiontype sectorg sectattrs {
		sect_SetLoadSection($3, (enum SectionType)$5, $6, $7, $2);
	}
	| T_POP_ENDL {
		sect_EndLoadSection();
	}
;

rept:
	T_POP_REPT uconst T_NEWLINE capture_rept endofline {
		if ($4)
			fstk_RunRept($2, captureBody.lineNo, captureBody.body, captureBody.size);
	}
;

for:
	T_POP_FOR {
		lexer_ToggleStringExpansion(false);
	} T_ID {
		lexer_ToggleStringExpansion(true);
	} T_COMMA for_args T_NEWLINE capture_rept endofline {
		if ($8)
			fstk_RunFor(
				$3,
				$6.start,
				$6.stop,
				$6.step,
				captureBody.lineNo,
				captureBody.body,
				captureBody.size
			);
	}
;

capture_rept:
	%empty {
		$$ = lexer_CaptureRept(captureBody);
	}
;

for_args:
	const {
		$$.start = 0;
		$$.stop = $1;
		$$.step = 1;
	}
	| const T_COMMA const {
		$$.start = $1;
		$$.stop = $3;
		$$.step = 1;
	}
	| const T_COMMA const T_COMMA const {
		$$.start = $1;
		$$.stop = $3;
		$$.step = $5;
	}
;

break:
	label T_POP_BREAK endofline {
		if (fstk_Break())
			lexer_SetMode(LEXER_SKIP_TO_ENDR);
	}
;

macrodef:
	T_POP_MACRO {
		lexer_ToggleStringExpansion(false);
	} T_ID {
		lexer_ToggleStringExpansion(true);
	} T_NEWLINE capture_macro endofline {
		if ($6)
			sym_AddMacro($3, captureBody.lineNo, captureBody.body, captureBody.size);
	}
;

capture_macro:
	%empty {
		$$ = lexer_CaptureMacroBody(captureBody);
	}
;

rsset:
	T_POP_RSSET uconst {
		sym_AddVar("_RS", $2);
	}
;

rsreset:
	T_POP_RSRESET {
		sym_AddVar("_RS", 0);
	}
;

rs_uconst:
	%empty {
		$$ = 1;
	}
	| uconst
;

union:
	T_POP_UNION {
		sect_StartUnion();
	}
;

nextu:
	T_POP_NEXTU {
		sect_NextUnionMember();
	}
;

endu:
	T_POP_ENDU {
		sect_EndUnion();
	}
;

ds:
	T_POP_DS uconst {
		sect_Skip($2, true);
	}
	| T_POP_DS uconst T_COMMA ds_args trailing_comma {
		sect_RelBytes($2, *$4);
		delete $4;
	}
	| T_POP_DS T_OP_ALIGN T_LBRACK align_spec T_RBRACK trailing_comma {
		uint32_t n = sect_GetAlignBytes($4.alignment, $4.alignOfs);

		sect_Skip(n, true);
		sect_AlignPC($4.alignment, $4.alignOfs);
	}
	| T_POP_DS T_OP_ALIGN T_LBRACK align_spec T_RBRACK T_COMMA ds_args trailing_comma {
		uint32_t n = sect_GetAlignBytes($4.alignment, $4.alignOfs);

		sect_RelBytes(n, *$7);
		sect_AlignPC($4.alignment, $4.alignOfs);
		delete $7;
	}
;

ds_args:
	reloc_8bit {
		initDsArgList($$);
		$$->push_back($1);
	}
	| ds_args T_COMMA reloc_8bit {
		$1->push_back($3);
		$$ = $1;
	}
;

db:
	T_POP_DB {
		sect_Skip(1, false);
	}
	| T_POP_DB constlist_8bit trailing_comma
;

dw:
	T_POP_DW {
		sect_Skip(2, false);
	}
	| T_POP_DW constlist_16bit trailing_comma
;

dl:
	T_POP_DL {
		sect_Skip(4, false);
	}
	| T_POP_DL constlist_32bit trailing_comma
;

def_equ:
	def_id T_POP_EQU const {
		sym_AddEqu($1, $3);
	}
;

redef_equ:
	redef_id T_POP_EQU const {
		sym_RedefEqu($1, $3);
	}
;

def_set:
	def_id T_POP_EQUAL const {
		sym_AddVar($1, $3);
	}
	| redef_id T_POP_EQUAL const {
		sym_AddVar($1, $3);
	}
	| def_id compoundeq const {
		compoundAssignment($1, $2, $3);
	}
	| redef_id compoundeq const {
		compoundAssignment($1, $2, $3);
	}
;

def_rb:
	def_id T_POP_RB rs_uconst {
		sym_AddEqu($1, sym_GetConstantValue("_RS"));
		sym_AddVar("_RS", sym_GetConstantValue("_RS") + $3);
	}
;

def_rw:
	def_id T_POP_RW rs_uconst {
		sym_AddEqu($1, sym_GetConstantValue("_RS"));
		sym_AddVar("_RS", sym_GetConstantValue("_RS") + 2 * $3);
	}
;

def_rl:
	def_id T_Z80_RL rs_uconst {
		sym_AddEqu($1, sym_GetConstantValue("_RS"));
		sym_AddVar("_RS", sym_GetConstantValue("_RS") + 4 * $3);
	}
;

def_equs:
	def_id T_POP_EQUS string {
		sym_AddString($1, $3);
	}
;

redef_equs:
	redef_id T_POP_EQUS string {
		sym_RedefString($1, $3);
	}
;

purge:
	T_POP_PURGE {
		lexer_ToggleStringExpansion(false);
	} purge_args trailing_comma {
		for (std::string &arg : *$3)
			sym_Purge(arg);
		delete $3;
		lexer_ToggleStringExpansion(true);
	}
;

purge_args:
	scoped_id {
		initPurgeArgList($$);
		$$->push_back($1);
	}
	| purge_args T_COMMA scoped_id {
		$1->push_back($3);
		$$ = $1;
	}
;

export: T_POP_EXPORT export_list trailing_comma;

export_list:
	  export_list_entry
	| export_list T_COMMA export_list_entry
;

export_list_entry:
	scoped_id {
		sym_Export($1);
	}
;

include:
	label T_POP_INCLUDE string endofline {
		fstk_RunInclude($3);
		if (failedOnMissingInclude)
			YYACCEPT;
	}
;

incbin:
	T_POP_INCBIN string {
		sect_BinaryFile($2, 0);
		if (failedOnMissingInclude)
			YYACCEPT;
	}
	| T_POP_INCBIN string T_COMMA const {
		sect_BinaryFile($2, $4);
		if (failedOnMissingInclude)
			YYACCEPT;
	}
	| T_POP_INCBIN string T_COMMA const T_COMMA const {
		sect_BinaryFileSlice($2, $4, $6);
		if (failedOnMissingInclude)
			YYACCEPT;
	}
;

charmap:
	T_POP_CHARMAP string T_COMMA const_8bit {
		charmap_Add($2, (uint8_t)$4);
	}
;

newcharmap:
	T_POP_NEWCHARMAP T_ID {
		charmap_New($2, nullptr);
	}
	| T_POP_NEWCHARMAP T_ID T_COMMA T_ID {
		charmap_New($2, $4);
	}
;

setcharmap:
	T_POP_SETCHARMAP T_ID {
		charmap_Set($2);
	}
;

pushc:
	T_POP_PUSHC {
		charmap_Push();
	}
;

popc:
	T_POP_POPC {
		charmap_Pop();
	}
;

print: T_POP_PRINT print_exprs trailing_comma;

println:
	T_POP_PRINTLN {
		putchar('\n');
		fflush(stdout);
	}
	| T_POP_PRINTLN print_exprs trailing_comma {
		putchar('\n');
		fflush(stdout);
	}
;

print_exprs:
	  print_expr
	| print_exprs T_COMMA print_expr
;

print_expr:
	const_no_str {
		printf("$%" PRIX32, $1);
	}
	| string {
		fputs($1, stdout);
	}
;

const_3bit:
	const {
		int32_t value = $1;

		if ((value < 0) || (value > 7)) {
			error("Immediate value must be 3-bit\n");
			$$ = 0;
		} else {
			$$ = value & 0x7;
		}
	}
;

constlist_8bit:
	  constlist_8bit_entry
	| constlist_8bit T_COMMA constlist_8bit_entry
;

constlist_8bit_entry:
	reloc_8bit_no_str {
		sect_RelByte($1, 0);
	}
	| string {
		std::vector<uint8_t> output;

		charmap_Convert($1, output);
		sect_AbsByteGroup(output.data(), output.size());
	}
;

constlist_16bit:
	  constlist_16bit_entry
	| constlist_16bit T_COMMA constlist_16bit_entry
;

constlist_16bit_entry:
	reloc_16bit_no_str {
		sect_RelWord($1, 0);
	}
	| string {
		std::vector<uint8_t> output;

		charmap_Convert($1, output);
		sect_AbsWordGroup(output.data(), output.size());
	}
;

constlist_32bit:
	  constlist_32bit_entry
	| constlist_32bit T_COMMA constlist_32bit_entry
;

constlist_32bit_entry:
	relocexpr_no_str {
		sect_RelLong($1, 0);
	}
	| string {
		std::vector<uint8_t> output;

		charmap_Convert($1, output);
		sect_AbsLongGroup(output.data(), output.size());
	}
;

reloc_8bit:
	relocexpr {
		rpn_CheckNBit($1, 8);
		$$ = $1;
	}
;

reloc_8bit_no_str:
	relocexpr_no_str {
		rpn_CheckNBit($1, 8);
		$$ = $1;
	}
;

reloc_8bit_offset:
	T_OP_ADD relocexpr {
		rpn_CheckNBit($2, 8);
		$$ = $2;
	}
	| T_OP_SUB relocexpr {
		rpn_NEG($$, $2);
		rpn_CheckNBit($$, 8);
	}
;

reloc_16bit:
	relocexpr {
		rpn_CheckNBit($1, 16);
		$$ = $1;
	}
;

reloc_16bit_no_str:
	relocexpr_no_str {
		rpn_CheckNBit($1, 16);
		$$ = $1;
	}
;

relocexpr:
	  relocexpr_no_str
	| string {
		std::vector<uint8_t> output;

		charmap_Convert($1, output);
		rpn_Number($$, str2int2(output));
	}
;

relocexpr_no_str:
	scoped_anon_id {
		rpn_Symbol($$, $1);
	}
	| T_NUMBER {
		rpn_Number($$, $1);
	}
	| T_OP_LOGICNOT relocexpr %prec NEG {
		rpn_LOGNOT($$, $2);
	}
	| relocexpr T_OP_LOGICOR relocexpr {
		rpn_BinaryOp(RPN_LOGOR, $$, $1, $3);
	}
	| relocexpr T_OP_LOGICAND relocexpr {
		rpn_BinaryOp(RPN_LOGAND, $$, $1, $3);
	}
	| relocexpr T_OP_LOGICEQU relocexpr {
		rpn_BinaryOp(RPN_LOGEQ, $$, $1, $3);
	}
	| relocexpr T_OP_LOGICGT relocexpr {
		rpn_BinaryOp(RPN_LOGGT, $$, $1, $3);
	}
	| relocexpr T_OP_LOGICLT relocexpr {
		rpn_BinaryOp(RPN_LOGLT, $$, $1, $3);
	}
	| relocexpr T_OP_LOGICGE relocexpr {
		rpn_BinaryOp(RPN_LOGGE, $$, $1, $3);
	}
	| relocexpr T_OP_LOGICLE relocexpr {
		rpn_BinaryOp(RPN_LOGLE, $$, $1, $3);
	}
	| relocexpr T_OP_LOGICNE relocexpr {
		rpn_BinaryOp(RPN_LOGNE, $$, $1, $3);
	}
	| relocexpr T_OP_ADD relocexpr {
		rpn_BinaryOp(RPN_ADD, $$, $1, $3);
	}
	| relocexpr T_OP_SUB relocexpr {
		rpn_BinaryOp(RPN_SUB, $$, $1, $3);
	}
	| relocexpr T_OP_XOR relocexpr {
		rpn_BinaryOp(RPN_XOR, $$, $1, $3);
	}
	| relocexpr T_OP_OR relocexpr {
		rpn_BinaryOp(RPN_OR, $$, $1, $3);
	}
	| relocexpr T_OP_AND relocexpr {
		rpn_BinaryOp(RPN_AND, $$, $1, $3);
	}
	| relocexpr T_OP_SHL relocexpr {
		rpn_BinaryOp(RPN_SHL, $$, $1, $3);
	}
	| relocexpr T_OP_SHR relocexpr {
		rpn_BinaryOp(RPN_SHR, $$, $1, $3);
	}
	| relocexpr T_OP_USHR relocexpr {
		rpn_BinaryOp(RPN_USHR, $$, $1, $3);
	}
	| relocexpr T_OP_MUL relocexpr {
		rpn_BinaryOp(RPN_MUL, $$, $1, $3);
	}
	| relocexpr T_OP_DIV relocexpr {
		rpn_BinaryOp(RPN_DIV, $$, $1, $3);
	}
	| relocexpr T_OP_MOD relocexpr {
		rpn_BinaryOp(RPN_MOD, $$, $1, $3);
	}
	| relocexpr T_OP_EXP relocexpr {
		rpn_BinaryOp(RPN_EXP, $$, $1, $3);
	}
	| T_OP_ADD relocexpr %prec NEG {
		$$ = $2;
	}
	| T_OP_SUB relocexpr %prec NEG {
		rpn_NEG($$, $2);
	}
	| T_OP_NOT relocexpr %prec NEG {
		rpn_NOT($$, $2);
	}
	| T_OP_HIGH T_LPAREN relocexpr T_RPAREN {
		rpn_HIGH($$, $3);
	}
	| T_OP_LOW T_LPAREN relocexpr T_RPAREN {
		rpn_LOW($$, $3);
	}
	| T_OP_ISCONST T_LPAREN relocexpr T_RPAREN {
		rpn_ISCONST($$, $3);
	}
	| T_OP_BANK T_LPAREN scoped_anon_id T_RPAREN {
		// '@' is also a T_ID; it is handled here
		rpn_BankSymbol($$, $3);
	}
	| T_OP_BANK T_LPAREN string T_RPAREN {
		rpn_BankSection($$, $3);
	}
	| T_OP_SIZEOF T_LPAREN string T_RPAREN {
		rpn_SizeOfSection($$, $3);
	}
	| T_OP_STARTOF T_LPAREN string T_RPAREN {
		rpn_StartOfSection($$, $3);
	}
	| T_OP_SIZEOF T_LPAREN sectiontype T_RPAREN {
		rpn_SizeOfSectionType($$, (enum SectionType)$3);
	}
	| T_OP_STARTOF T_LPAREN sectiontype T_RPAREN {
		rpn_StartOfSectionType($$, (enum SectionType)$3);
	}
	| T_OP_DEF {
		lexer_ToggleStringExpansion(false);
	} T_LPAREN scoped_anon_id T_RPAREN {
		rpn_Number($$, sym_FindScopedValidSymbol($4) != nullptr);

		lexer_ToggleStringExpansion(true);
	}
	| T_OP_ROUND T_LPAREN const opt_q_arg T_RPAREN {
		rpn_Number($$, fix_Round($3, $4));
	}
	| T_OP_CEIL T_LPAREN const opt_q_arg T_RPAREN {
		rpn_Number($$, fix_Ceil($3, $4));
	}
	| T_OP_FLOOR T_LPAREN const opt_q_arg T_RPAREN {
		rpn_Number($$, fix_Floor($3, $4));
	}
	| T_OP_FDIV T_LPAREN const T_COMMA const opt_q_arg T_RPAREN {
		rpn_Number($$, fix_Div($3, $5, $6));
	}
	| T_OP_FMUL T_LPAREN const T_COMMA const opt_q_arg T_RPAREN {
		rpn_Number($$, fix_Mul($3, $5, $6));
	}
	| T_OP_FMOD T_LPAREN const T_COMMA const opt_q_arg T_RPAREN {
		rpn_Number($$, fix_Mod($3, $5, $6));
	}
	| T_OP_POW T_LPAREN const T_COMMA const opt_q_arg T_RPAREN {
		rpn_Number($$, fix_Pow($3, $5, $6));
	}
	| T_OP_LOG T_LPAREN const T_COMMA const opt_q_arg T_RPAREN {
		rpn_Number($$, fix_Log($3, $5, $6));
	}
	| T_OP_SIN T_LPAREN const opt_q_arg T_RPAREN {
		rpn_Number($$, fix_Sin($3, $4));
	}
	| T_OP_COS T_LPAREN const opt_q_arg T_RPAREN {
		rpn_Number($$, fix_Cos($3, $4));
	}
	| T_OP_TAN T_LPAREN const opt_q_arg T_RPAREN {
		rpn_Number($$, fix_Tan($3, $4));
	}
	| T_OP_ASIN T_LPAREN const opt_q_arg T_RPAREN {
		rpn_Number($$, fix_ASin($3, $4));
	}
	| T_OP_ACOS T_LPAREN const opt_q_arg T_RPAREN {
		rpn_Number($$, fix_ACos($3, $4));
	}
	| T_OP_ATAN T_LPAREN const opt_q_arg T_RPAREN {
		rpn_Number($$, fix_ATan($3, $4));
	}
	| T_OP_ATAN2 T_LPAREN const T_COMMA const opt_q_arg T_RPAREN {
		rpn_Number($$, fix_ATan2($3, $5, $6));
	}
	| T_OP_STRCMP T_LPAREN string T_COMMA string T_RPAREN {
		rpn_Number($$, strcmp($3, $5));
	}
	| T_OP_STRIN T_LPAREN string T_COMMA string T_RPAREN {
		char const *p = strstr($3, $5);

		rpn_Number($$, p ? p - $3 + 1 : 0);
	}
	| T_OP_STRRIN T_LPAREN string T_COMMA string T_RPAREN {
		char const *p = strrstr($3, $5);

		rpn_Number($$, p ? p - $3 + 1 : 0);
	}
	| T_OP_STRLEN T_LPAREN string T_RPAREN {
		rpn_Number($$, strlenUTF8($3));
	}
	| T_OP_CHARLEN T_LPAREN string T_RPAREN {
		rpn_Number($$, charlenUTF8($3));
	}
	| T_OP_INCHARMAP T_LPAREN string T_RPAREN {
		rpn_Number($$, charmap_HasChar($3));
	}
	| T_LPAREN relocexpr T_RPAREN {
		$$ = $2;
	}
;

uconst:
	const {
		if ($1 < 0)
			fatalerror("Constant must not be negative: %d\n", $1);
		$$ = $1;
	}
;

const:
	relocexpr {
		$$ = $1.getConstVal();
	}
;

const_no_str:
	relocexpr_no_str {
		$$ = $1.getConstVal();
	}
;

const_8bit:
	reloc_8bit {
		$$ = $1.getConstVal();
	}
;

opt_q_arg:
	%empty {
		$$ = fix_Precision();
	}
	| T_COMMA const {
		if ($2 >= 1 && $2 <= 31) {
			$$ = $2;
		} else {
			error("Fixed-point precision must be between 1 and 31\n");
			$$ = fix_Precision();
		}
	}
;

string:
	  T_STRING
	| T_OP_STRSUB T_LPAREN string T_COMMA const T_COMMA uconst T_RPAREN {
		size_t len = strlenUTF8($3);
		uint32_t pos = adjustNegativePos($5, len, "STRSUB");

		strsubUTF8($$, sizeof($$), $3, pos, $7);
	}
	| T_OP_STRSUB T_LPAREN string T_COMMA const T_RPAREN {
		size_t len = strlenUTF8($3);
		uint32_t pos = adjustNegativePos($5, len, "STRSUB");

		strsubUTF8($$, sizeof($$), $3, pos, pos > len ? 0 : len + 1 - pos);
	}
	| T_OP_CHARSUB T_LPAREN string T_COMMA const T_RPAREN {
		size_t len = charlenUTF8($3);
		uint32_t pos = adjustNegativePos($5, len, "CHARSUB");

		charsubUTF8($$, $3, pos);
	}
	| T_OP_STRCAT T_LPAREN T_RPAREN {
		$$[0] = '\0';
	}
	| T_OP_STRCAT T_LPAREN strcat_args T_RPAREN {
		strcpy($$, $3);
	}
	| T_OP_STRUPR T_LPAREN string T_RPAREN {
		upperstring($$, $3);
	}
	| T_OP_STRLWR T_LPAREN string T_RPAREN {
		lowerstring($$, $3);
	}
	| T_OP_STRRPL T_LPAREN string T_COMMA string T_COMMA string T_RPAREN {
		strrpl($$, sizeof($$), $3, $5, $7);
	}
	| T_OP_STRFMT T_LPAREN strfmt_args T_RPAREN {
		strfmt($$, sizeof($$), $3.format->c_str(), *$3.args);
		freeStrFmtArgList($3);
	}
	| T_POP_SECTION T_LPAREN scoped_anon_id T_RPAREN {
		Symbol *sym = sym_FindScopedValidSymbol($3);

		if (!sym)
			fatalerror("Unknown symbol \"%s\"\n", $3);
		Section const *section = sym->getSection();

		if (!section)
			fatalerror("\"%s\" does not belong to any section\n", sym->name);
		// Section names are capped by rgbasm's maximum string length,
		// so this currently can't overflow.
		strcpy($$, section->name.c_str());
	}
;

strcat_args:
	  string
	| strcat_args T_COMMA string {
		int ret = snprintf($$, sizeof($$), "%s%s", $1, $3);

		if (ret == -1)
			fatalerror("snprintf error in STRCAT: %s\n", strerror(errno));
		else if ((unsigned int)ret >= sizeof($$))
			warning(WARNING_LONG_STR, "STRCAT: String too long '%s%s'\n", $1, $3);
	}
;

strfmt_args:
	string strfmt_va_args {
		$$ = $2;
		*$$.format = $1;
	}
;

strfmt_va_args:
	%empty {
		initStrFmtArgList($$);
	}
	| strfmt_va_args T_COMMA const_no_str {
		$1.args->push_back((uint32_t)$3);
		$$ = $1;
	}
	| strfmt_va_args T_COMMA string {
		$1.args->push_back($3);
		$$ = $1;
	}
;

section:
	T_POP_SECTION sectmod string T_COMMA sectiontype sectorg sectattrs {
		sect_NewSection($3, (enum SectionType)$5, $6, $7, $2);
	}
;

sectmod:
	%empty {
		$$ = SECTION_NORMAL;
	}
	| T_POP_UNION {
		$$ = SECTION_UNION;
	}
	| T_POP_FRAGMENT {
		$$ = SECTION_FRAGMENT;
	}
;

sectiontype:
	T_SECT_WRAM0 {
		$$ = SECTTYPE_WRAM0;
	}
	| T_SECT_VRAM {
		$$ = SECTTYPE_VRAM;
	}
	| T_SECT_ROMX {
		$$ = SECTTYPE_ROMX;
	}
	| T_SECT_ROM0 {
		$$ = SECTTYPE_ROM0;
	}
	| T_SECT_HRAM {
		$$ = SECTTYPE_HRAM;
	}
	| T_SECT_WRAMX {
		$$ = SECTTYPE_WRAMX;
	}
	| T_SECT_SRAM {
		$$ = SECTTYPE_SRAM;
	}
	| T_SECT_OAM {
		$$ = SECTTYPE_OAM;
	}
;

sectorg:
	%empty {
		$$ = -1;
	}
	| T_LBRACK uconst T_RBRACK {
		if ($2 < 0 || $2 >= 0x10000) {
			error("Address $%x is not 16-bit\n", $2);
			$$ = -1;
		} else {
			$$ = $2;
		}
	}
;

sectattrs:
	%empty {
		$$.alignment = 0;
		$$.alignOfs = 0;
		$$.bank = -1;
	}
	| sectattrs T_COMMA T_OP_ALIGN T_LBRACK align_spec T_RBRACK {
		$$ = $1;
		$$.alignment = $5.alignment;
		$$.alignOfs = $5.alignOfs;
	}
	| sectattrs T_COMMA T_OP_BANK T_LBRACK uconst T_RBRACK {
		$$ = $1;
		$$.bank = $5; // We cannot check the validity of this yet
	}
;

// CPU commands.

cpu_commands:
	  cpu_command
	| cpu_command T_DOUBLE_COLON cpu_commands
;

cpu_command:
	  z80_adc
	| z80_add
	| z80_and
	| z80_bit
	| z80_call
	| z80_ccf
	| z80_cp
	| z80_cpl
	| z80_daa
	| z80_dec
	| z80_di
	| z80_ei
	| z80_halt
	| z80_inc
	| z80_jp
	| z80_jr
	| z80_ld
	| z80_ldd
	| z80_ldi
	| z80_ldio
	| z80_nop
	| z80_or
	| z80_pop
	| z80_push
	| z80_res
	| z80_ret
	| z80_reti
	| z80_rl
	| z80_rla
	| z80_rlc
	| z80_rlca
	| z80_rr
	| z80_rra
	| z80_rrc
	| z80_rrca
	| z80_rst
	| z80_sbc
	| z80_scf
	| z80_set
	| z80_sla
	| z80_sra
	| z80_srl
	| z80_stop
	| z80_sub
	| z80_swap
	| z80_xor
;

z80_adc:
	T_Z80_ADC op_a_n {
		sect_AbsByte(0xCE);
		sect_RelByte($2, 1);
	}
	| T_Z80_ADC op_a_r {
		sect_AbsByte(0x88 | $2);
	}
;

z80_add:
	T_Z80_ADD op_a_n {
		sect_AbsByte(0xC6);
		sect_RelByte($2, 1);
	}
	| T_Z80_ADD op_a_r {
		sect_AbsByte(0x80 | $2);
	}
	| T_Z80_ADD T_MODE_HL T_COMMA reg_ss {
		sect_AbsByte(0x09 | ($4 << 4));
	}
	| T_Z80_ADD T_MODE_SP T_COMMA reloc_8bit {
		sect_AbsByte(0xE8);
		sect_RelByte($4, 1);
	}
;

z80_and:
	T_Z80_AND op_a_n {
		sect_AbsByte(0xE6);
		sect_RelByte($2, 1);
	}
	| T_Z80_AND op_a_r {
		sect_AbsByte(0xA0 | $2);
	}
;

z80_bit:
	T_Z80_BIT const_3bit T_COMMA reg_r {
		sect_AbsByte(0xCB);
		sect_AbsByte(0x40 | ($2 << 3) | $4);
	}
;

z80_call:
	T_Z80_CALL reloc_16bit {
		sect_AbsByte(0xCD);
		sect_RelWord($2, 1);
	}
	| T_Z80_CALL ccode_expr T_COMMA reloc_16bit {
		sect_AbsByte(0xC4 | ($2 << 3));
		sect_RelWord($4, 1);
	}
;

z80_ccf:
	T_Z80_CCF {
		sect_AbsByte(0x3F);
	}
;

z80_cp:
	T_Z80_CP op_a_n {
		sect_AbsByte(0xFE);
		sect_RelByte($2, 1);
	}
	| T_Z80_CP op_a_r {
		sect_AbsByte(0xB8 | $2);
	}
;

z80_cpl:
	T_Z80_CPL {
		sect_AbsByte(0x2F);
	}
;

z80_daa:
	T_Z80_DAA {
		sect_AbsByte(0x27);
	}
;

z80_dec:
	T_Z80_DEC reg_r {
		sect_AbsByte(0x05 | ($2 << 3));
	}
	| T_Z80_DEC reg_ss {
		sect_AbsByte(0x0B | ($2 << 4));
	}
;

z80_di:
	T_Z80_DI {
		sect_AbsByte(0xF3);
	}
;

z80_ei:
	T_Z80_EI {
		sect_AbsByte(0xFB);
	}
;

z80_halt:
	T_Z80_HALT {
		sect_AbsByte(0x76);
		if (haltNop) {
			if (warnOnHaltNop) {
				warnOnHaltNop = false;
				warning(
					WARNING_OBSOLETE,
					"Automatic `nop` after `halt` (option 'H') is deprecated\n"
				);
			}
			sect_AbsByte(0x00);
		}
	}
;

z80_inc:
	T_Z80_INC reg_r {
		sect_AbsByte(0x04 | ($2 << 3));
	}
	| T_Z80_INC reg_ss {
		sect_AbsByte(0x03 | ($2 << 4));
	}
;

z80_jp:
	T_Z80_JP reloc_16bit {
		sect_AbsByte(0xC3);
		sect_RelWord($2, 1);
	}
	| T_Z80_JP ccode_expr T_COMMA reloc_16bit {
		sect_AbsByte(0xC2 | ($2 << 3));
		sect_RelWord($4, 1);
	}
	| T_Z80_JP T_MODE_HL {
		sect_AbsByte(0xE9);
	}
;

z80_jr:
	T_Z80_JR reloc_16bit {
		sect_AbsByte(0x18);
		sect_PCRelByte($2, 1);
	}
	| T_Z80_JR ccode_expr T_COMMA reloc_16bit {
		sect_AbsByte(0x20 | ($2 << 3));
		sect_PCRelByte($4, 1);
	}
;

z80_ldi:
	T_Z80_LDI T_LBRACK T_MODE_HL T_RBRACK T_COMMA T_MODE_A {
		sect_AbsByte(0x02 | (2 << 4));
	}
	| T_Z80_LDI T_MODE_A T_COMMA T_LBRACK T_MODE_HL T_RBRACK {
		sect_AbsByte(0x0A | (2 << 4));
	}
;

z80_ldd:
	T_Z80_LDD T_LBRACK T_MODE_HL T_RBRACK T_COMMA T_MODE_A {
		sect_AbsByte(0x02 | (3 << 4));
	}
	| T_Z80_LDD T_MODE_A T_COMMA T_LBRACK T_MODE_HL T_RBRACK {
		sect_AbsByte(0x0A | (3 << 4));
	}
;

z80_ldio:
	T_Z80_LDH T_MODE_A T_COMMA op_mem_ind {
		rpn_CheckHRAM($4, $4);

		sect_AbsByte(0xF0);
		sect_RelByte($4, 1);
	}
	| T_Z80_LDH op_mem_ind T_COMMA T_MODE_A {
		rpn_CheckHRAM($2, $2);

		sect_AbsByte(0xE0);
		sect_RelByte($2, 1);
	}
	| T_Z80_LDH T_MODE_A T_COMMA c_ind {
		sect_AbsByte(0xF2);
	}
	| T_Z80_LDH c_ind T_COMMA T_MODE_A {
		sect_AbsByte(0xE2);
	}
;

c_ind:
	  T_LBRACK T_MODE_C T_RBRACK
	| T_LBRACK relocexpr T_OP_ADD T_MODE_C T_RBRACK {
		if (!$2.isKnown || $2.val != 0xFF00)
			error("Expected constant expression equal to $FF00 for \"$ff00+c\"\n");
	}
;

z80_ld:
	  z80_ld_mem
	| z80_ld_cind
	| z80_ld_rr
	| z80_ld_ss
	| z80_ld_hl
	| z80_ld_sp
	| z80_ld_r
	| z80_ld_a
;

z80_ld_hl:
	T_Z80_LD T_MODE_HL T_COMMA T_MODE_SP reloc_8bit_offset {
		sect_AbsByte(0xF8);
		sect_RelByte($5, 1);
	}
	| T_Z80_LD T_MODE_HL T_COMMA reloc_16bit {
		sect_AbsByte(0x01 | (REG_HL << 4));
		sect_RelWord($4, 1);
	}
;

z80_ld_sp:
	T_Z80_LD T_MODE_SP T_COMMA T_MODE_HL {
		sect_AbsByte(0xF9);
	}
	| T_Z80_LD T_MODE_SP T_COMMA reloc_16bit {
		sect_AbsByte(0x01 | (REG_SP << 4));
		sect_RelWord($4, 1);
	}
;

z80_ld_mem:
	T_Z80_LD op_mem_ind T_COMMA T_MODE_SP {
		sect_AbsByte(0x08);
		sect_RelWord($2, 1);
	}
	| T_Z80_LD op_mem_ind T_COMMA T_MODE_A {
		if (optimizeLoads && $2.isKnown && $2.val >= 0xFF00) {
			if (warnOnLdOpt) {
				warnOnLdOpt = false;
				warning(
					WARNING_OBSOLETE,
					"Automatic `ld` to `ldh` optimization (option 'l') is deprecated\n"
				);
			}
			sect_AbsByte(0xE0);
			sect_AbsByte($2.val & 0xFF);
			rpn_Free($2);
		} else {
			sect_AbsByte(0xEA);
			sect_RelWord($2, 1);
		}
	}
;

z80_ld_cind:
	T_Z80_LD c_ind T_COMMA T_MODE_A {
		sect_AbsByte(0xE2);
	}
;

z80_ld_rr:
	T_Z80_LD reg_rr T_COMMA T_MODE_A {
		sect_AbsByte(0x02 | ($2 << 4));
	}
;

z80_ld_r:
	T_Z80_LD reg_r T_COMMA reloc_8bit {
		sect_AbsByte(0x06 | ($2 << 3));
		sect_RelByte($4, 1);
	}
	| T_Z80_LD reg_r T_COMMA reg_r {
		if (($2 == REG_HL_IND) && ($4 == REG_HL_IND))
			error("LD [HL],[HL] not a valid instruction\n");
		else
			sect_AbsByte(0x40 | ($2 << 3) | $4);
	}
;

z80_ld_a:
	T_Z80_LD reg_r T_COMMA c_ind {
		if ($2 == REG_A)
			sect_AbsByte(0xF2);
		else
			error("Destination operand must be A\n");
	}
	| T_Z80_LD reg_r T_COMMA reg_rr {
		if ($2 == REG_A)
			sect_AbsByte(0x0A | ($4 << 4));
		else
			error("Destination operand must be A\n");
	}
	| T_Z80_LD reg_r T_COMMA op_mem_ind {
		if ($2 == REG_A) {
			if (optimizeLoads && $4.isKnown && $4.val >= 0xFF00) {
				if (warnOnLdOpt) {
					warnOnLdOpt = false;
					warning(
						WARNING_OBSOLETE,
						"Automatic `ld` to `ldh` optimization (option 'l') is deprecated\n"
					);
				}
				sect_AbsByte(0xF0);
				sect_AbsByte($4.val & 0xFF);
				rpn_Free($4);
			} else {
				sect_AbsByte(0xFA);
				sect_RelWord($4, 1);
			}
		} else {
			error("Destination operand must be A\n");
			rpn_Free($4);
		}
	}
;

z80_ld_ss:
	T_Z80_LD T_MODE_BC T_COMMA reloc_16bit {
		sect_AbsByte(0x01 | (REG_BC << 4));
		sect_RelWord($4, 1);
	}
	| T_Z80_LD T_MODE_DE T_COMMA reloc_16bit {
		sect_AbsByte(0x01 | (REG_DE << 4));
		sect_RelWord($4, 1);
	}
	// HL is taken care of in z80_ld_hl
	// SP is taken care of in z80_ld_sp
;

z80_nop:
	T_Z80_NOP {
		sect_AbsByte(0x00);
	}
;

z80_or:
	T_Z80_OR op_a_n {
		sect_AbsByte(0xF6);
		sect_RelByte($2, 1);
	}
	| T_Z80_OR op_a_r {
		sect_AbsByte(0xB0 | $2);
	}
;

z80_pop:
	T_Z80_POP reg_tt {
		sect_AbsByte(0xC1 | ($2 << 4));
	}
;

z80_push:
	T_Z80_PUSH reg_tt {
		sect_AbsByte(0xC5 | ($2 << 4));
	}
;

z80_res:
	T_Z80_RES const_3bit T_COMMA reg_r {
		sect_AbsByte(0xCB);
		sect_AbsByte(0x80 | ($2 << 3) | $4);
	}
;

z80_ret:
	T_Z80_RET {
		sect_AbsByte(0xC9);
	}
	| T_Z80_RET ccode_expr {
		sect_AbsByte(0xC0 | ($2 << 3));
	}
;

z80_reti:
	T_Z80_RETI {
		sect_AbsByte(0xD9);
	}
;

z80_rl:
	T_Z80_RL reg_r {
		sect_AbsByte(0xCB);
		sect_AbsByte(0x10 | $2);
	}
;

z80_rla:
	T_Z80_RLA {
		sect_AbsByte(0x17);
	}
;

z80_rlc:
	T_Z80_RLC reg_r {
		sect_AbsByte(0xCB);
		sect_AbsByte(0x00 | $2);
	}
;

z80_rlca:
	T_Z80_RLCA {
		sect_AbsByte(0x07);
	}
;

z80_rr:
	T_Z80_RR reg_r {
		sect_AbsByte(0xCB);
		sect_AbsByte(0x18 | $2);
	}
;

z80_rra:
	T_Z80_RRA {
		sect_AbsByte(0x1F);
	}
;

z80_rrc:
	T_Z80_RRC reg_r {
		sect_AbsByte(0xCB);
		sect_AbsByte(0x08 | $2);
	}
;

z80_rrca:
	T_Z80_RRCA {
		sect_AbsByte(0x0F);
	}
;

z80_rst:
	T_Z80_RST reloc_8bit {
		rpn_CheckRST($2, $2);
		if (!$2.isKnown)
			sect_RelByte($2, 0);
		else
			sect_AbsByte(0xC7 | $2.val);
		rpn_Free($2);
	}
;

z80_sbc:
	T_Z80_SBC op_a_n {
		sect_AbsByte(0xDE);
		sect_RelByte($2, 1);
	}
	| T_Z80_SBC op_a_r {
		sect_AbsByte(0x98 | $2);
	}
;

z80_scf:
	T_Z80_SCF {
		sect_AbsByte(0x37);
	}
;

z80_set:
	T_Z80_SET const_3bit T_COMMA reg_r {
		sect_AbsByte(0xCB);
		sect_AbsByte(0xC0 | ($2 << 3) | $4);
	}
;

z80_sla:
	T_Z80_SLA reg_r {
		sect_AbsByte(0xCB);
		sect_AbsByte(0x20 | $2);
	}
;

z80_sra:
	T_Z80_SRA reg_r {
		sect_AbsByte(0xCB);
		sect_AbsByte(0x28 | $2);
	}
;

z80_srl:
	T_Z80_SRL reg_r {
		sect_AbsByte(0xCB);
		sect_AbsByte(0x38 | $2);
	}
;

z80_stop:
	T_Z80_STOP {
		sect_AbsByte(0x10);
		sect_AbsByte(0x00);
	}
	| T_Z80_STOP reloc_8bit {
		sect_AbsByte(0x10);
		sect_RelByte($2, 1);
	}
;

z80_sub:
	T_Z80_SUB op_a_n {
		sect_AbsByte(0xD6);
		sect_RelByte($2, 1);
	}
	| T_Z80_SUB op_a_r {
		sect_AbsByte(0x90 | $2);
	}
;

z80_swap:
	T_Z80_SWAP reg_r {
		sect_AbsByte(0xCB);
		sect_AbsByte(0x30 | $2);
	}
;

z80_xor:
	T_Z80_XOR op_a_n {
		sect_AbsByte(0xEE);
		sect_RelByte($2, 1);
	}
	| T_Z80_XOR op_a_r {
		sect_AbsByte(0xA8 | $2);
	}
;

// Registers or values.

op_mem_ind:
	T_LBRACK reloc_16bit T_RBRACK {
		$$ = $2;
	}
;

op_a_r:
	  reg_r
	| T_MODE_A T_COMMA reg_r {
		$$ = $3;
	}
;

op_a_n:
	  reloc_8bit
	| T_MODE_A T_COMMA reloc_8bit {
		$$ = $3;
	}
;

// Registers and condition codes.

T_MODE_A:
	  T_TOKEN_A
	| T_OP_HIGH T_LPAREN T_MODE_AF T_RPAREN
;

T_MODE_B:
	  T_TOKEN_B
	| T_OP_HIGH T_LPAREN T_MODE_BC T_RPAREN
;

T_MODE_C:
	  T_TOKEN_C
	| T_OP_LOW T_LPAREN T_MODE_BC T_RPAREN
;

T_MODE_D:
	  T_TOKEN_D
	| T_OP_HIGH T_LPAREN T_MODE_DE T_RPAREN
;

T_MODE_E:
	  T_TOKEN_E
	| T_OP_LOW T_LPAREN T_MODE_DE T_RPAREN
;

T_MODE_H:
	  T_TOKEN_H
	| T_OP_HIGH T_LPAREN T_MODE_HL T_RPAREN
;

T_MODE_L:
	  T_TOKEN_L
	| T_OP_LOW T_LPAREN T_MODE_HL T_RPAREN
;

ccode_expr:
	  ccode
	| T_OP_LOGICNOT ccode_expr {
		$$ = $2 ^ 1;
	}
;

ccode:
	T_CC_NZ {
		$$ = CC_NZ;
	}
	| T_CC_Z {
		$$ = CC_Z;
	}
	| T_CC_NC {
		$$ = CC_NC;
	}
	| T_TOKEN_C {
		$$ = CC_C;
	}
;

reg_r:
	T_MODE_B {
		$$ = REG_B;
	}
	| T_MODE_C {
		$$ = REG_C;
	}
	| T_MODE_D {
		$$ = REG_D;
	}
	| T_MODE_E {
		$$ = REG_E;
	}
	| T_MODE_H {
		$$ = REG_H;
	}
	| T_MODE_L {
		$$ = REG_L;
	}
	| T_LBRACK T_MODE_HL T_RBRACK {
		$$ = REG_HL_IND;
	}
	| T_MODE_A {
		$$ = REG_A;
	}
;

reg_tt:
	T_MODE_BC {
		$$ = REG_BC;
	}
	| T_MODE_DE {
		$$ = REG_DE;
	}
	| T_MODE_HL {
		$$ = REG_HL;
	}
	| T_MODE_AF {
		$$ = REG_AF;
	}
;

reg_ss:
	T_MODE_BC {
		$$ = REG_BC;
	}
	| T_MODE_DE {
		$$ = REG_DE;
	}
	| T_MODE_HL {
		$$ = REG_HL;
	}
	| T_MODE_SP {
		$$ = REG_SP;
	}
;

reg_rr:
	T_LBRACK T_MODE_BC T_RBRACK {
		$$ = REG_BC_IND;
	}
	| T_LBRACK T_MODE_DE T_RBRACK {
		$$ = REG_DE_IND;
	}
	| hl_ind_inc {
		$$ = REG_HL_INDINC;
	}
	| hl_ind_dec {
		$$ = REG_HL_INDDEC;
	}
;

hl_ind_inc:
	  T_LBRACK T_MODE_HL_INC T_RBRACK
	| T_LBRACK T_MODE_HL T_OP_ADD T_RBRACK
;

hl_ind_dec:
	  T_LBRACK T_MODE_HL_DEC T_RBRACK
	| T_LBRACK T_MODE_HL T_OP_SUB T_RBRACK
;

%%

// Semantic actions.

static void upperstring(char *dest, char const *src) {
	while (*src)
		*dest++ = toupper(*src++);
	*dest = '\0';
}

static void lowerstring(char *dest, char const *src) {
	while (*src)
		*dest++ = tolower(*src++);
	*dest = '\0';
}

static uint32_t str2int2(std::vector<uint8_t> const &s) {
	uint32_t length = s.size();

	if (length > 4)
		warning(
		    WARNING_NUMERIC_STRING_1,
		    "Treating string as a number ignores first %" PRIu32 " character%s\n", length - 4,
		    length == 5 ? "" : "s"
		);
	else if (length > 1)
		warning(
		    WARNING_NUMERIC_STRING_2, "Treating %" PRIu32 "-character string as a number\n", length
		);

	uint32_t r = 0;

	for (uint32_t i = length < 4 ? 0 : length - 4; i < length; i++) {
		r <<= 8;
		r |= s[i];
	}

	return r;
}

static const char *strrstr(char const *s1, char const *s2) {
	size_t len1 = strlen(s1);
	size_t len2 = strlen(s2);

	if (len2 > len1)
		return nullptr;

	for (char const *p = s1 + len1 - len2; p >= s1; p--)
		if (!strncmp(p, s2, len2))
			return p;

	return nullptr;
}

static void errorInvalidUTF8Byte(uint8_t byte, char const *functionName) {
	error("%s: Invalid UTF-8 byte 0x%02hhX\n", functionName, byte);
}

static size_t strlenUTF8(char const *s) {
	size_t len = 0;
	uint32_t state = 0;

	for (uint32_t codep = 0; *s; s++) {
		uint8_t byte = *s;

		switch (decode(&state, &codep, byte)) {
		case 1:
			errorInvalidUTF8Byte(byte, "STRLEN");
			state = 0;
			// fallthrough
		case 0:
			len++;
			break;
		}
	}

	// Check for partial code point.
	if (state != 0)
		error("STRLEN: Incomplete UTF-8 character\n");

	return len;
}

static void strsubUTF8(char *dest, size_t destLen, char const *src, uint32_t pos, uint32_t len) {
	size_t srcIndex = 0;
	size_t destIndex = 0;
	uint32_t state = 0;
	uint32_t codep = 0;
	uint32_t curLen = 0;
	uint32_t curPos = 1;

	// Advance to starting position in source string.
	while (src[srcIndex] && curPos < pos) {
		switch (decode(&state, &codep, src[srcIndex])) {
		case 1:
			errorInvalidUTF8Byte(src[srcIndex], "STRSUB");
			state = 0;
			// fallthrough
		case 0:
			curPos++;
			break;
		}
		srcIndex++;
	}

	// A position 1 past the end of the string is allowed, but will trigger the
	// "Length too big" warning below if the length is nonzero.
	if (!src[srcIndex] && pos > curPos)
		warning(
		    WARNING_BUILTIN_ARG, "STRSUB: Position %" PRIu32 " is past the end of the string\n", pos
		);

	// Copy from source to destination.
	while (src[srcIndex] && destIndex < destLen - 1 && curLen < len) {
		switch (decode(&state, &codep, src[srcIndex])) {
		case 1:
			errorInvalidUTF8Byte(src[srcIndex], "STRSUB");
			state = 0;
			// fallthrough
		case 0:
			curLen++;
			break;
		}
		dest[destIndex++] = src[srcIndex++];
	}

	if (curLen < len)
		warning(WARNING_BUILTIN_ARG, "STRSUB: Length too big: %" PRIu32 "\n", len);

	// Check for partial code point.
	if (state != 0)
		error("STRSUB: Incomplete UTF-8 character\n");

	dest[destIndex] = '\0';
}

static size_t charlenUTF8(char const *str) {
	size_t len;

	for (len = 0; charmap_ConvertNext(str, nullptr); len++)
		;

	return len;
}

static void charsubUTF8(char *dest, char const *src, uint32_t pos) {
	size_t charLen = 1;

	// Advance to starting position in source string.
	for (uint32_t curPos = 1; charLen && curPos < pos; curPos++)
		charLen = charmap_ConvertNext(src, nullptr);

	char const *start = src;

	if (!charmap_ConvertNext(src, nullptr))
		warning(
		    WARNING_BUILTIN_ARG, "CHARSUB: Position %" PRIu32 " is past the end of the string\n",
		    pos
		);

	// Copy from source to destination.
	memcpy(dest, start, src - start);

	dest[src - start] = '\0';
}

static uint32_t adjustNegativePos(int32_t pos, size_t len, char const *functionName) {
	// STRSUB and CHARSUB adjust negative `pos` arguments the same way,
	// such that position -1 is the last character of a string.
	if (pos < 0)
		pos += len + 1;
	if (pos < 1) {
		warning(WARNING_BUILTIN_ARG, "%s: Position starts at 1\n", functionName);
		pos = 1;
	}
	return (uint32_t)pos;
}

static void strrpl(char *dest, size_t destLen, char const *src, char const *old, char const *rep) {
	size_t oldLen = strlen(old);
	size_t repLen = strlen(rep);
	size_t i = 0;

	if (!oldLen) {
		warning(WARNING_EMPTY_STRRPL, "STRRPL: Cannot replace an empty string\n");
		strcpy(dest, src);
		return;
	}

	for (char const *next = strstr(src, old); next && *next; next = strstr(src, old)) {
		// Copy anything before the substring to replace
		unsigned int lenBefore = next - src;

		memcpy(dest + i, src, lenBefore < destLen - i ? lenBefore : destLen - i);
		i += next - src;
		if (i >= destLen)
			break;

		// Copy the replacement substring
		memcpy(dest + i, rep, repLen < destLen - i ? repLen : destLen - i);
		i += repLen;
		if (i >= destLen)
			break;

		src = next + oldLen;
	}

	if (i < destLen) {
		size_t srcLen = strlen(src);

		// Copy anything after the last replaced substring
		memcpy(dest + i, src, srcLen < destLen - i ? srcLen : destLen - i);
		i += srcLen;
	}

	if (i >= destLen) {
		warning(WARNING_LONG_STR, "STRRPL: String too long, got truncated\n");
		i = destLen - 1;
	}
	dest[i] = '\0';
}

static void initStrFmtArgList(StrFmtArgList &args) {
	args.format = new (std::nothrow) std::string();
	if (!args.format)
		fatalerror("Failed to allocate memory for STRFMT format string: %s\n", strerror(errno));
	args.args = new (std::nothrow) std::vector<std::variant<uint32_t, std::string>>();
	if (!args.args)
		fatalerror("Failed to allocate memory for STRFMT arg list: %s\n", strerror(errno));
}

static void freeStrFmtArgList(StrFmtArgList &args) {
	delete args.format;
	delete args.args;
}

static void strfmt(
    char *dest, size_t destLen, char const *spec,
    std::vector<std::variant<uint32_t, std::string>> &args
) {
	size_t a = 0;
	size_t i = 0;

	while (i < destLen) {
		int c = *spec++;

		if (c == '\0') {
			break;
		} else if (c != '%') {
			dest[i++] = c;
			continue;
		}

		c = *spec++;

		if (c == '%') {
			dest[i++] = c;
			continue;
		}

		FormatSpec fmt{};

		while (c != '\0') {
			fmt.useCharacter(c);
			if (fmt.isFinished())
				break;
			c = *spec++;
		}

		if (fmt.isEmpty()) {
			error("STRFMT: Illegal '%%' at end of format string\n");
			dest[i++] = '%';
			break;
		} else if (!fmt.isValid()) {
			error("STRFMT: Invalid format spec for argument %zu\n", a + 1);
			dest[i++] = '%';
			a++;
			continue;
		} else if (a >= args.size()) {
			// Will warn after formatting is done.
			dest[i++] = '%';
			a++;
			continue;
		}

		std::variant<uint32_t, std::string> &arg = args[a++];
		static char buf[MAXSTRLEN + 1];

		std::visit(
		    Visitor{
		        [&](uint32_t num) { fmt.printNumber(buf, sizeof(buf), num); },
		        [&](std::string &str) { fmt.printString(buf, sizeof(buf), str.c_str()); },
		    },
		    arg
		);

		i += snprintf(&dest[i], destLen - i, "%s", buf);
	}

	if (a < args.size())
		error("STRFMT: %zu unformatted argument(s)\n", args.size() - a);
	else if (a > args.size())
		error(
		    "STRFMT: Not enough arguments for format spec, got: %zu, need: %zu\n", args.size(), a
		);

	if (i > destLen - 1) {
		warning(WARNING_LONG_STR, "STRFMT: String too long, got truncated\n");
		i = destLen - 1;
	}
	dest[i] = '\0';
}

static void compoundAssignment(const char *symName, enum RPNCommand op, int32_t constValue) {
	Expression oldExpr, constExpr, newExpr;
	int32_t newValue;

	rpn_Symbol(oldExpr, symName);
	rpn_Number(constExpr, constValue);
	rpn_BinaryOp(op, newExpr, oldExpr, constExpr);
	newValue = newExpr.getConstVal();
	sym_AddVar(symName, newValue);
}

static void initDsArgList(std::vector<Expression> *&args) {
	args = new (std::nothrow) std::vector<Expression>();
	if (!args)
		fatalerror("Failed to allocate memory for ds arg list: %s\n", strerror(errno));
}

static void initPurgeArgList(std::vector<std::string> *&args) {
	args = new (std::nothrow) std::vector<std::string>();
	if (!args)
		fatalerror("Failed to allocate memory for purge arg list: %s\n", strerror(errno));
}

static void failAssert(enum AssertionType type) {
	switch (type) {
	case ASSERT_FATAL:
		fatalerror("Assertion failed\n");
	case ASSERT_ERROR:
		error("Assertion failed\n");
		break;
	case ASSERT_WARN:
		warning(WARNING_ASSERT, "Assertion failed\n");
		break;
	}
}

static void failAssertMsg(enum AssertionType type, char const *msg) {
	switch (type) {
	case ASSERT_FATAL:
		fatalerror("Assertion failed: %s\n", msg);
	case ASSERT_ERROR:
		error("Assertion failed: %s\n", msg);
		break;
	case ASSERT_WARN:
		warning(WARNING_ASSERT, "Assertion failed: %s\n", msg);
		break;
	}
}

void yyerror(char const *str) {
	error("%s\n", str);
}
