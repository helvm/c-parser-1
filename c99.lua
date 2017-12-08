-- C99 grammar written in lpeg.re.
-- Adapted and translated from plain LPeg grammar for C99
-- written by Wesley Smith https://github.com/Flymir/ceg
--
-- Copyright (c) 2009 Wesley Smith
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
-- THE SOFTWARE.

-- Reference used in the original and in this implementation:
-- http://www.open-std.org/JTC1/SC22/wg14/www/docs/n1124.pdf

local c99 = {}

local re = require("relabel")

local defs = {}

--[[ not yet clear if this is necessary

-- Transforms strings into literal patterns of the same name.
-- If "minus" is passed, each pattern is concatenated to it.
local function apply(dst, src, minus)
    local ret = lpeg.P(false)
    for _, v in ipairs(src) do
        local UP = string.upper(v)
        dst[UP] = lpeg.P(v)
        if minus then
            dst[UP] = dst[UP] * minus
        end
        ret = dst[UP] + ret
    end
    return ret
end

local keywords = {
    'auto',     'enum',     'restrict', 'unsigned',
    'break',    'extern',   'return',   'void',
    'case',     'float',    'short',    'volatile',
    'char',     'for',      'signed',   'while',
    'const',    'goto',     'sizeof',   '_Bool',
    'continue', 'if',       'static',   '_Complex',
    'default',  'inline',   'struct',   '_Imaginary',
    'do',       'int',      'switch',
    'double',   'long',     'typedef',
    'else',     'register', 'union',
}

apply(defs, keywords, -(lpeg.R'09' + lpeg.R('__','az','AZ')))

]]

--==============================================================================
-- Common Rules (used in both preprocessing and language processing)
--==============================================================================

local common_rules = [[--lpeg.re

TRACE <- ({} => trace)

--------------------------------------------------------------------------------
-- Identifiers

identifier <- { identifierNondigit (identifierNondigit / [0-9])* }
identifierNondigit <- [a-zA-Z_]
                    / universalCharacterName

identifierList <- identifier (_ "," _ identifier)*

--------------------------------------------------------------------------------
-- Universal Character Names

universalCharacterName <- "\u" hexQuad
                        / "\U" hexQuad hexQuad

hexQuad <- hexDigit^4

--------------------------------------------------------------------------------
-- String Literals

stringLiteral <- { ('"' / 'L"') sChar+ '"' }

sChar <- (!["\%nl] .) / escapeSequence

--------------------------------------------------------------------------------
-- Escape Sequences

escapeSequence <- simpleEscapeSequence
                / octalEscapeSequence
                / hexEscapeSequence
                / universalCharacterName

simpleEscapeSequence <- "\" ['"?\abfnrtv]

octalEscapeSequence <- "\" [0-7] [0-7]^-2

hexEscapeSequence <- "\x" hexDigit+

--------------------------------------------------------------------------------
-- Constants

integerConstant <- hexConstant integerSuffix?
                 / octalConstant integerSuffix?
                 / decimalConstant integerSuffix?

decimalConstant <- [1-9] digit*
octalConstant <- "0" [0-7]*
hexConstant <- ("0x" / "0X") hexDigit+

digit <- [0-9]
hexDigit <- [0-9a-fA-F]

integerSuffix <- unsignedSuffix longSuffix?
               / unsignedSuffix longLongSuffix
               / longLongSuffix unsignedSuffix?
               / longSuffix unsignedSuffix?

unsignedSuffix <- [uU]
longSuffix <- [lL]
longLongSuffix <- "ll" / "LL"

floatingConstant <- decimalFloatingConstant
                  / hexFloatingConstant

decimalFloatingConstant <- fractionalConstant exponentPart? floatingSuffix?
                         / digit+ exponentPart floatingSuffix?

hexFloatingConstant <- ("0x" / "0X" ) ( hexFractionalConstant binaryExponentPart floatingSuffix?
                                      /  hexDigit+ binaryExponentPart floatingSuffix? )

fractionalConstant <- digit* "." digit+
                    / digit "."

exponentPart <- [eE] [-+]? digit+

hexFractionalConstant <- hexDigit+? "." hexDigit+
                       / hexDigit+ "."

binaryExponentPart <- [pP] digit+

floatingSuffix <- [flFL]

characterConstant <- { ("'" / "L'") cChar+ "'" }

cChar <- (!['\%nl] .) / escapeSequence

enumerationConstant <- identifier

]]

local common_expression_rules = [[--lpeg.re

--------------------------------------------------------------------------------
-- Common Expression Rules

multiplicativeExpression <- {| castExpression           (_ {:op: [*/%]                     :} _ castExpression                          )* |}
additiveExpression       <- {| multiplicativeExpression (_ {:op: [-+]                      :} _ multiplicativeExpression                )* |}
shiftExpression          <- {| additiveExpression       (_ {:op: ("<<" / ">>")             :} _ additiveExpression                      )* |}
relationalExpression     <- {| shiftExpression          (_ {:op: (">=" / "<=" / "<" / ">") :} _ shiftExpression                         )* |}
equalityExpression       <- {| relationalExpression     (_ {:op: ("==" / "!=")             :} _ relationalExpression                    )* |}
bandExpression           <- {| equalityExpression       (_ {:op: "&"                       :} _ equalityExpression                      )* |}
bxorExpression           <- {| bandExpression           (_ {:op: "^"                       :} _ bandExpression                          )* |}
borExpression            <- {| bxorExpression           (_ {:op: "|"                       :} _ bxorExpression                          )* |}
andExpression            <- {| borExpression            (_ {:op: "&&"                      :} _ borExpression                           )* |}
orExpression             <- {| andExpression            (_ {:op: "||"                      :} _ andExpression                           )* |}
conditionalExpression    <- {| orExpression             (_ {:op: "?"                       :} _ expression _ ":" _ conditionalExpression)? |}

constantExpression <- conditionalExpression

]]

--==============================================================================
-- Language Rules (Phrase Structure Grammar)
--==============================================================================

local language_rules = [[--lpeg.re

--------------------------------------------------------------------------------
-- External Definitions

translationUnit <- %s* {| (externalDeclaration _)+ |} "<EOF>"

externalDeclaration <- functionDefinition
                     / declaration

functionDefinition <- {| (declarationSpecifier _)+ {:function: declarator :} _ (declaration _)* compoundStatement |}

--------------------------------------------------------------------------------
-- Declarations

declaration <- {| {:type: ({ declarationSpecifier } _)+ :} {:ids: initDeclarationList? :} _ ";" |} => store_typedef

declarationSpecifier <- storageClassSpecifier
                      / typeSpecifier
                      / typeQualifier
                      / functionSpecifier

initDeclarationList <- initDeclarator (_ "," _ initDeclarator)*

initDeclarator <- declarator (_ "=" _ initializer)?

storageClassSpecifier <- "typedef" / "extern" / "static" / "auto" / "register"

typeSpecifier <- "void" / "char" / "short" / "int" / "long"
               / "float" / "double" / "signed" / "unsigned"
               / "_Bool" / "Complex"
               / structOrUnionSpecifier
               / enumSpecifier
               / typedefName => valid_typedef

structOrUnionSpecifier <- structOrUnion (_ identifier)? _ "{" _ (structDeclaration _)+ "}"
                           / structOrUnion _ identifier

structOrUnion <- "struct" / "union"

structDeclaration <- specifierQualifierList structDeclaratorList _ ";"

specifierQualifierList <- ((typeSpecifier / typeQualifier) _)+

structDeclaratorList <- structDeclarator (_ "," _ structDeclarator)*

structDeclarator <- declarator
                  / (declarator _)? ":" _ constantExpression

enumSpecifier <- "enum" (_ identifier)? _ "{" _ enumeratorList (_ ",")? _ "}"
               / "enum" _ identifier

enumeratorList <- enumerator (_ "," _ enumerator)*

enumerator <- enumerationConstant (_ "=" _ constantExpression)?

typeQualifier <- "const" / "restrict" / "volatile"

functionSpecifier <- "inline"

declarator <- (pointer _)? directDeclarator

directDeclarator <- identifier ddRec
                  / "(" _ declarator _ ")" ddRec
ddRec <- _ "[" _ (typeQualifier _)* (assignmentExpression _)? "]" ddRec
       / _ "[" _ "static" _ (typeQualifier _)* assignmentExpression _ "]" ddRec
       / _ "[" _ (typeQualifier _)+ "static" _ assignmentExpression _ "]" ddRec
       / _ "[" _ (typeQualifier _)* "*" _ "]" ddRec
       / _ "(" _ parameterTypeList _ ")" ddRec
       / _ "(" _ (identifierList _)? ")" ddRec
       / ""

pointer <- ("*" (_ typeQualifier)*) (_ "*" (_ typeQualifier)*)*

parameterTypeList <- parameterList (_ "," _ "...")?

parameterList <- parameterDeclaration (_ "," _ parameterDeclaration)*

parameterDeclaration <- (declarationSpecifier _)+ (declarator / abstractDeclarator?) -- TODO

typeName <- specifierQualifierList (_ abstractDeclarator)?

abstractDeclarator <- pointer
                    / (pointer _)? directAbstractDeclarator

directAbstractDeclarator <- ("(" _ abstractDeclarator _ ")" ) (_ directAbstractDeclarator2)*
                          / (_ directAbstractDeclarator2)+
directAbstractDeclarator2 <- "[" _ assignmentExpression? _ "]"
                           / "[" _ "*" _ "]"
                           / "(" _ parameterTypeList? _ ")"

typedefName <- identifier

initializer <- assignmentExpression
             / "{" _ initializerList (_ ",")? _ "}"

initializerList <- initializerList2 (_ "," _ initializerList2)*
initializerList2 <- designation? _ initializer

designation <- (_ designator)+ _ "="

designator <- "[" _ constantExpression _ "]"
            / "." _ identifier

--------------------------------------------------------------------------------
-- Statements

statement <- labeledStatement
           / compoundStatement
           / expressionStatement
           / selectionStatement
           / iterationStatement
           / jumpStatement

labeledStatement <- identifier _ ":" _ statement
                  / "case" _ constantExpression _ ":" _ statement
                  / "default" _ ":" _ statement

compoundStatement <- "{" _ blockItemList _ "}"

blockItemList <- (_ blockItem)+

blockItem <- declaration
           / statement

expressionStatement <- expression? _ ";"

selectionStatement <- "if" _ "(" _ expression _ ")" _ statement _ "else" _ statement
                    / "if" _ "(" _ expression _ ")" _ statement
                    / "switch" _ "(" _ expression _ ")" _ statement

iterationStatement <- "while" _ "(" _ expression _ ")" _ statement
                    / "do" _ statement _ "while" _ "(" _ expression _ ")" _ ";"
                    / "for" _ "(" _ expression? _ ";" _ expression? _ ";" _ expression? _ ")" _ statement
                    / "for" _ "(" _ declaration _ expression? _ ";" _ expression? _ ")" _ statement

jumpStatement <- "goto" _ identifier _ ";"
               / "continue" _ ";"
               / "break" _ ";"
               / "return" (_ expression)? _ ";"

--------------------------------------------------------------------------------
-- Language Expression Rules
-- (rules which differ from preprocessing stage)

constant <- floatingConstant
          / integerConstant
          / characterConstant
          / enumerationConstant

primaryExpression <- identifier
                   / constant
                   / stringLiteral
                   / "(" _ expression _ ")"

postfixExpression <- primaryExpression peRec
                   / "(" _ typeName _ ")" _ "{" _ initializerList (_ ",")? _ "}" peRec
peRec <- _ "[" _ expression _ "]" _ peRec
       / _ "(" _ argumentExpressionList? _ ")" _ peRec
       / _ "." _ identifier _ peRec
       / _ "->" _ identifier _ peRec
       / _ "++" _ peRec
       / _ "--" _ peRec
       / ""

argumentExpressionList <- assignmentExpression (_ "," _ assignmentExpression)*

unaryExpression <- postfixExpression
                 / ("++" / "--") unaryExpression
                 / unaryOperator _ castExpression
                 / "sizeof" _ unaryExpression
                 / "sizeof" _ "(" _ typeName _ ")"

unaryOperator <- [-+~!*&]

castExpression <- "(" _ typeName _ ")" _ castExpression
                / unaryExpression

assignmentExpression <- conditionalExpression
                      / unaryExpression _ assignmentOperator _ assignmentExpression

assignmentOperator <- "=" / "*=" / "/=" / "%=" / "+=" / "-="
                    / "<<=" / ">>=" / "&=" / "^=" / "|="

expression <- assignmentExpression (_ "," _ assignmentExpression)*

--------------------------------------------------------------------------------
-- Language whitespace

_ <- %s+
S <- %s+

]]

--==============================================================================
-- Preprocessing Rules
--==============================================================================

local util = require("titan-compiler.util")

c99.tracing = false

defs["trace"] = function(s, i)
    if c99.tracing then
        local line, col = util.get_line_number(s, i)
        print("TRACE", line, col)
    end
    return true
end

local typedefs = {}

defs["store_typedef"] = function(s, i, decl)
    if decl.type == "typedef" then
        if type(decl.ids) == "string" then
            typedefs[decl.ids] = true
        end
    end
    --print((require("inspect"))(decl))
    return true
end

defs["valid_typedef"] = function(s, i, id)
    return typedefs[id]
    -- print("is " .. id .. " a typedef? no")
    --return false
end

local preprocessing_rules = [[--lpeg.re

preprocessingLine <- _ ( "#" _ {| directive |} _
                       / {| preprocessingTokens? |} _
                       / "#" _ preprocessingTokens? _ -- non-directive, ignore
                       )

preprocessingTokens <- {| (preprocessingToken _)+ |}

directive <- {:directive: "if"      :} S {:exp: preprocessingTokens :}
           / {:directive: "ifdef"   :} S {:id: identifier :}
           / {:directive: "ifndef"  :} S {:id: identifier :}
           / {:directive: "elif"    :} S {:exp: preprocessingTokens :}
           / {:directive: "else"    :}
           / {:directive: "endif"   :}
           / {:directive: "include" :} S {:exp: headerName :}
           / {:directive: "define"  :} S {:id: identifier :} "(" _ {:args: {| defineArgs |} :} _ ")" _ {:repl: replacementList :}
           / {:directive: "define"  :} S {:id: identifier :} _ {:repl: replacementList :}
           / {:directive: "undef"   :} S {:id: identifier :}
           / {:directive: "line"    :} S {:line: preprocessingTokens :}
           / {:directive: "error"   :} S {:error: preprocessingTokens? :}
           / {:directive: "pragma"  :} S {:pragma: preprocessingTokens? :}
           / ""

defineArgs <- { "..." }
            / identifierList _ "," _ { "..." }
            / identifierList?

replacementList <- {| (preprocessingToken _)* |}

preprocessingToken <- identifier
                    / preprocessingNumber
                    / characterConstant
                    / stringLiteral
                    / punctuator

headerName <- {| {:mode: "<" -> "system" :} { (![%nl>] .)+ } ">" |}
            / {| {:mode: '"' -> "quote" :} { (![%nl"] .)+ } '"' |}

preprocessingNumber <- { ("."? digit) ( digit
                                      / identifierNondigit
                                      / [eEpP] [-+]
                                      / "."
                                      )* }

punctuator <- { digraphs / '...' / '<<=' / '>>=' /
                '##' / '<<' / '>>' / '->' / '++' / '--' / '&&' / '||' / '<=' / '>=' /
                '==' / '!=' / '*=' / '/=' / '%=' / '+=' / '-=' / '&=' / '^=' / '|=' /
                '#' / '[' / ']' / '(' / ')' / '{' / '}' / '.' / '&' /
                '*' / '+' / '-' / '~' / '!' / '/' / '%' / '<' / '>' /
                '^' / '|' / '?' / ':' / ';' / ',' / '=' }

digraphs <- '%:%:' -> "##"
          / '%:' -> "#"
          / '<:' -> "["
          / ':>' -> "]"
          / '<%' -> "{"
          / '%>' -> "}"

--------------------------------------------------------------------------------
-- Preprocessing whitespace

_ <- %s*
S <- %s+

]]

local preprocessing_expression_rules = [[--lpeg.re

--------------------------------------------------------------------------------
-- Preprocessing Expression Rules
-- (rules which differ from language processing stage)

expression <- constantExpression

constant <- { ( floatingConstant
              / integerConstant
              / characterConstant
              ) }

primaryExpression <- identifier
                   / constant
                   / {| "(" _ expression _ ")" |}

postfixExpression <- primaryExpression peRec
peRec <- _ "(" _ argumentExpressionList? _ ")" peRec
       / ""

argumentExpressionList <- {| { expression } (_ "," _ { expression } )* |}

unaryExpression <- {| {:op: unaryOperator :} _ {:exp: unaryExpression :} |}
                 / primaryExpression

unaryOperator <- [-+~!] / "defined"

castExpression <- unaryExpression

--------------------------------------------------------------------------------
-- Preprocessing expression whitespace

_ <- %s*
S <- %s+

]]

c99.preprocessing_grammar = re.compile(
    preprocessing_rules ..
    common_rules, defs)

c99.preprocessing_expression_grammar = re.compile(
    preprocessing_expression_rules ..
    common_rules ..
    common_expression_rules, defs)

c99.language_grammar = re.compile(
    language_rules ..
    common_rules ..
    common_expression_rules, defs)

return c99
