/*
 * This file is part of RGBDS.
 *
 * Copyright (c) 1997-2018, Carsten Sorensen and RGBDS contributors.
 *
 * SPDX-License-Identifier: MIT
 */

/*
 * FileStack routines
 */

#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>

#include "asm/fstack.h"
#include "asm/lexer.h"
#include "asm/macro.h"
#include "asm/main.h"
#include "asm/output.h"
#include "asm/warning.h"

#include "extern/err.h"

#include "platform.h" // S_ISDIR (stat macro)
#include "types.h"

static struct sContext *pFileStack;
static unsigned int nFileStackDepth;
unsigned int nMaxRecursionDepth;
static struct Symbol const *pCurrentMacro;
static uint32_t nCurrentStatus;
static char IncludePaths[MAXINCPATHS][_MAX_PATH + 1];
static int32_t NextIncPath;
static uint32_t nMacroCount;

static char *pCurrentREPTBlock;
static uint32_t nCurrentREPTBlockSize;
static uint32_t nCurrentREPTBlockCount;
static int32_t nCurrentREPTBodyFirstLine;
static int32_t nCurrentREPTBodyLastLine;

uint32_t ulMacroReturnValue;

/*
 * defines for nCurrentStatus
 */
#define STAT_isInclude		0 /* 'Normal' state as well */
#define STAT_isMacro		1
#define STAT_isMacroArg		2
#define STAT_isREPTBlock	3

/* Max context stack size */

/*
 * Context push and pop
 */
static void pushcontext(void)
{
	struct sContext **ppFileStack;

	if (++nFileStackDepth > nMaxRecursionDepth)
		fatalerror("Recursion limit (%u) exceeded\n", nMaxRecursionDepth);

	ppFileStack = &pFileStack;
	while (*ppFileStack)
		ppFileStack = &((*ppFileStack)->next);

	*ppFileStack = malloc(sizeof(struct sContext));

	if (*ppFileStack == NULL)
		fatalerror("No memory for context\n");

	(*ppFileStack)->next = NULL;
	(*ppFileStack)->nLine = lexer_GetLineNo();

	switch ((*ppFileStack)->nStatus = nCurrentStatus) {
	case STAT_isMacroArg:
	case STAT_isMacro:
		(*ppFileStack)->macroArgs = macro_GetCurrentArgs();
		(*ppFileStack)->pMacro = pCurrentMacro;
		break;
	case STAT_isInclude:
		break;
	case STAT_isREPTBlock:
		(*ppFileStack)->macroArgs = macro_GetCurrentArgs();
		(*ppFileStack)->pREPTBlock = pCurrentREPTBlock;
		(*ppFileStack)->nREPTBlockSize = nCurrentREPTBlockSize;
		(*ppFileStack)->nREPTBlockCount = nCurrentREPTBlockCount;
		(*ppFileStack)->nREPTBodyFirstLine = nCurrentREPTBodyFirstLine;
		(*ppFileStack)->nREPTBodyLastLine = nCurrentREPTBodyLastLine;
		break;
	default:
		fatalerror("%s: Internal error.\n", __func__);
	}
	(*ppFileStack)->uniqueID = macro_GetUniqueID();
}

static int32_t popcontext(void)
{
	struct sContext *pLastFile, **ppLastFile;

	if (nCurrentStatus == STAT_isREPTBlock) {
		if (--nCurrentREPTBlockCount) {
			char *pREPTIterationWritePtr;
			unsigned long nREPTIterationNo;
			int nNbCharsWritten;
			int nNbCharsLeft;

			macro_SetUniqueID(nMacroCount++);

			/* Increment REPT count in file path */
			pREPTIterationWritePtr =
				strrchr(lexer_GetFileName(), '~') + 1;
			nREPTIterationNo =
				strtoul(pREPTIterationWritePtr, NULL, 10);
			nNbCharsLeft = sizeof(lexer_GetFileName())
				- (pREPTIterationWritePtr - lexer_GetFileName());
			nNbCharsWritten = snprintf(pREPTIterationWritePtr,
						   nNbCharsLeft, "%lu",
						   nREPTIterationNo + 1);
			if (nNbCharsWritten >= nNbCharsLeft) {
				/*
				 * The string is probably corrupted somehow,
				 * revert the change to avoid a bad error
				 * output.
				 */
				sprintf(pREPTIterationWritePtr, "%lu",
					nREPTIterationNo);
				fatalerror("Cannot write REPT count to file path\n");
			}

			return 0;
		}
	}

	pLastFile = pFileStack;
	if (pLastFile == NULL)
		return 1;

	ppLastFile = &pFileStack;
	while (pLastFile->next) {
		ppLastFile = &(pLastFile->next);
		pLastFile = *ppLastFile;
	}

	lexer_DeleteState(lexer_GetState());
	lexer_SetState(pLastFile->lexerState);

	switch (pLastFile->nStatus) {
		struct MacroArgs *args;

	case STAT_isMacroArg:
	case STAT_isMacro:
		args = macro_GetCurrentArgs();
		if (nCurrentStatus == STAT_isMacro) {
			macro_FreeArgs(args);
			free(args);
		}
		macro_UseNewArgs(pLastFile->macroArgs);
		pCurrentMacro = pLastFile->pMacro;
		break;
	case STAT_isInclude:
		break;
	case STAT_isREPTBlock:
		args = macro_GetCurrentArgs();
		if (nCurrentStatus == STAT_isMacro) {
			macro_FreeArgs(args);
			free(args);
		}
		macro_UseNewArgs(pLastFile->macroArgs);
		pCurrentREPTBlock = pLastFile->pREPTBlock;
		nCurrentREPTBlockSize = pLastFile->nREPTBlockSize;
		nCurrentREPTBlockCount = pLastFile->nREPTBlockCount;
		nCurrentREPTBodyFirstLine = pLastFile->nREPTBodyFirstLine;
		break;
	default:
		fatalerror("%s: Internal error.\n", __func__);
	}
	macro_SetUniqueID(pLastFile->uniqueID);

	nCurrentStatus = pLastFile->nStatus;

	nFileStackDepth--;

	free(*ppLastFile);
	*ppLastFile = NULL;
	return 0;
}

int32_t fstk_GetLine(void)
{
	struct sContext *pLastFile, **ppLastFile;

	switch (nCurrentStatus) {
	case STAT_isInclude:
		/* This is the normal mode, also used when including a file. */
		return lexer_GetLineNo();
	case STAT_isMacro:
		break; /* Peek top file of the stack */
	case STAT_isMacroArg:
		return lexer_GetLineNo(); /* ??? */
	case STAT_isREPTBlock:
		break; /* Peek top file of the stack */
	default:
		fatalerror("%s: Internal error.\n", __func__);
	}

	pLastFile = pFileStack;

	if (pLastFile != NULL) {
		while (pLastFile->next) {
			ppLastFile = &(pLastFile->next);
			pLastFile = *ppLastFile;
		}
		return pLastFile->nLine;
	}

	/*
	 * This is only reached if the lexer is in REPT or MACRO mode but there
	 * are no saved contexts with the origin of said REPT or MACRO.
	 */
	fatalerror("%s: Internal error.\n", __func__);
}

int yywrap(void)
{
	return popcontext();
}

/*
 * Dump the context stack to stderr
 */
void fstk_Dump(void)
{
	const struct sContext *pLastFile;

	pLastFile = pFileStack;

	while (pLastFile) {
		fprintf(stderr, "%s(%" PRId32 ") -> ", pLastFile->tzFileName,
			pLastFile->nLine);
		pLastFile = pLastFile->next;
	}

	fprintf(stderr, "%s(%" PRId32 ")", lexer_GetFileName(), lexer_GetLineNo());
}

void fstk_DumpToStr(char *buf, size_t buflen)
{
	const struct sContext *pLastFile = pFileStack;
	int retcode;
	size_t len = buflen;

	while (pLastFile) {
		retcode = snprintf(&buf[buflen - len], len, "%s(%" PRId32 ") -> ",
				   pLastFile->tzFileName, pLastFile->nLine);
		if (retcode < 0)
			fatalerror("Failed to dump file stack to string: %s\n", strerror(errno));
		else if (retcode >= len)
			len = 0;
		else
			len -= retcode;
		pLastFile = pLastFile->next;
	}

	retcode = snprintf(&buf[buflen - len], len, "%s(%" PRId32 ")",
			   lexer_GetFileName(), lexer_GetLineNo());
	if (retcode < 0)
		fatalerror("Failed to dump file stack to string: %s\n", strerror(errno));
	else if (retcode >= len)
		len = 0;
	else
		len -= retcode;

	if (!len)
		warning(WARNING_LONG_STR, "File stack dump too long, got truncated\n");
}

/*
 * Extra includepath stuff
 */
void fstk_AddIncludePath(char *s)
{
	if (NextIncPath == MAXINCPATHS)
		fatalerror("Too many include directories passed from command line\n");

	// Find last occurrence of slash; is it at the end of the string?
	char const *lastSlash = strrchr(s, '/');
	char const *pattern = lastSlash && *(lastSlash + 1) == 0 ? "%s" : "%s/";

	if (snprintf(IncludePaths[NextIncPath++], _MAX_PATH, pattern,
		     s) >= _MAX_PATH)
		fatalerror("Include path too long '%s'\n", s);
}

static void printdep(const char *fileName)
{
	if (dependfile) {
		fprintf(dependfile, "%s: %s\n", tzTargetFileName, fileName);
		if (oGeneratePhonyDeps)
			fprintf(dependfile, "%s:\n", fileName);
	}
}

static bool isPathValid(char const *pathname)
{
	struct stat statbuf;

	if (stat(pathname, &statbuf) != 0)
		return false;

	/* Reject directories */
	return !S_ISDIR(statbuf.st_mode);
}

bool fstk_FindFile(char const *path, char **fullPath, size_t *size)
{
	if (!*size) {
		*size = 64; /* This is arbitrary, really */
		*fullPath = realloc(*fullPath, *size);
		if (!*fullPath)
			error("realloc error during include path search: %s\n",
			      strerror(errno));
	}

	if (*fullPath) {
		for (size_t i = 0; i <= NextIncPath; ++i) {
			char *incPath = i ? IncludePaths[i - 1] : "";
			int len = snprintf(*fullPath, *size, "%s%s", incPath, path);

			/* Oh how I wish `asnprintf` was standard... */
			if (len >= *size) { /* `len` doesn't include the terminator, `size` does */
				*size = len + 1;
				*fullPath = realloc(*fullPath, *size);
				if (!*fullPath) {
					error("realloc error during include path search: %s\n",
					      strerror(errno));
					break;
				}
				len = sprintf(*fullPath, "%s%s", incPath, path);
			}

			if (len < 0) {
				error("snprintf error during include path search: %s\n",
				      strerror(errno));
			} else if (isPathValid(*fullPath)) {
				printdep(*fullPath);
				return true;
			}
		}
	}

	errno = ENOENT;
	if (oGeneratedMissingIncludes)
		printdep(path);
	return false;
}

/*
 * Set up an include file for parsing
 */
void fstk_RunInclude(char *tzFileName)
{
	char *fullPath = NULL;
	size_t size = 0;

	if (!fstk_FindFile(tzFileName, &fullPath, &size)) {
		if (oGeneratedMissingIncludes)
			oFailedOnMissingInclude = true;
		else
			error("Unable to open included file '%s': %s\n",
			      tzFileName, strerror(errno));
		free(fullPath);
		return;
	}

	pushcontext();
	nCurrentStatus = STAT_isInclude;
	if (verbose)
		printf("Assembling %s\n", fullPath);

	struct LexerState *state = lexer_OpenFile(fullPath);

	if (!state)
		/* If lexer had an error, it already reported it */
		fatalerror("Failed to open file for INCLUDE\n"); /* TODO: make this non-fatal? */
	lexer_SetStateAtEOL(state);
	free(fullPath);
}

/*
 * Set up a macro for parsing
 */
void fstk_RunMacro(char *s, struct MacroArgs *args)
{
	struct Symbol const *sym = sym_FindSymbol(s);

	if (sym == NULL) {
		error("Macro \"%s\" not defined\n", s);
		return;
	}
	if (sym->type != SYM_MACRO) {
		error("\"%s\" is not a macro\n", s);
		return;
	}

	pushcontext();
	macro_SetUniqueID(nMacroCount++);
	/* Minus 1 because there is a newline at the beginning of the buffer */
	macro_UseNewArgs(args);
	nCurrentStatus = STAT_isMacro;

	pCurrentMacro = sym;
}

/*
 * Set up a repeat block for parsing
 */
void fstk_RunRept(uint32_t count, int32_t nReptLineNo)
{
	if (count) {
		pushcontext();
		macro_SetUniqueID(nMacroCount++);
		nCurrentREPTBlockCount = count;
		nCurrentStatus = STAT_isREPTBlock;
		nCurrentREPTBlockSize = ulNewMacroSize;
		pCurrentREPTBlock = tzNewMacro;
		nCurrentREPTBodyFirstLine = nReptLineNo + 1;
	}
}

/*
 * Initialize the filestack routines
 */
void fstk_Init(char *pFileName)
{
	char tzSymFileName[_MAX_PATH + 1 + 2];

	char *c = pFileName;
	int fileNameIndex = 0;

	tzSymFileName[fileNameIndex++] = '"';

	// minus 2 to account for trailing "\"\0"
	// minus 1 to avoid a buffer overflow in extreme cases
	while (*c && fileNameIndex < sizeof(tzSymFileName) - 2 - 1) {
		if (*c == '"') {
			tzSymFileName[fileNameIndex++] = '\\';
		}

		tzSymFileName[fileNameIndex++] = *c;
		++c;
	}

	tzSymFileName[fileNameIndex++] = '"';
	tzSymFileName[fileNameIndex]   = '\0';

	sym_AddString("__FILE__", tzSymFileName);

	pFileStack = NULL;
	nFileStackDepth = 0;

	nMacroCount = 0;
	nCurrentStatus = STAT_isInclude;
}
