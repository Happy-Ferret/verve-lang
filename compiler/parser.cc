#include "parser.h"

#include "lexer.h"
#include "token.h"

namespace ceos {

  std::shared_ptr<AST::Program> Parser::parse(void) {
    m_types["Int"] = new BasicType("Int");
    m_types["Char"] = new BasicType("Char");
    m_types["Float"] = new BasicType("Float");
    m_types["Void"] = new BasicType("Void");
    m_types["List"] = new DataType("List", 1);
    m_types["String"] = new DataTypeInstance((DataType *)m_types["List"], (::ceos::Type *[]){ m_types["Char"] });

    m_ast = std::make_shared<AST::Program>();
    m_ast->loc.start = m_lexer.token()->loc.start;
    m_ast->body = parseBlock(Token::Type::END);
    m_ast->body->needsScope = false;
    return m_ast;
  }

  std::shared_ptr<AST::Block> Parser::parseBlock(Token::Type delim) {
    auto block = std::make_shared<AST::Block>();
    while (m_lexer.token()->type != delim) {
      std::shared_ptr<AST> node = parseFactor();
      if (node) {
        block->nodes.push_back(node);
      }
    }
    block->needsScope = m_scope->isRequired;
    block->capturesScope = m_scope->capturesScope;

    return block;
  }

  std::shared_ptr<AST> Parser::parseFactor() {
    switch (m_lexer.token()->type) {
      case Token::Type::NUMBER:
        return parseNumber();
      case Token::Type::ID:
        return parseID();
      case Token::Type::STRING:
        return parseString();
      default:
        m_lexer.invalidType();
    }
  }

  std::shared_ptr<AST> Parser::parseIf() {
    auto _if = std::make_shared<AST::If>();

    m_lexer.ensure(Token::Type::L_PAREN);
    _if->condition = parseFactor();
    m_lexer.ensure(Token::Type::R_PAREN);

    if (m_lexer.token()->type == Token::Type::L_BRACE) {
      m_lexer.ensure(Token::Type::L_BRACE);
      _if->ifBody = parseBlock(Token::Type::R_BRACE);
      m_lexer.ensure(Token::Type::R_BRACE);
    } else {
      auto ifBody = std::make_shared<AST::Block>();
      ifBody->nodes.push_back(parseFactor());
      _if->ifBody = ifBody;
    }

    if (m_lexer.token()->type == Token::Type::ID) {
      auto maybeElse = static_cast<Token::ID *>(m_lexer.token());
      if (maybeElse->name == "else") {
        m_lexer.ensure(Token::Type::ID);

        if (m_lexer.token()->type == Token::Type::L_BRACE) {
          m_lexer.ensure(Token::Type::L_BRACE);
          _if->elseBody = parseBlock(Token::Type::R_BRACE);
          m_lexer.ensure(Token::Type::R_BRACE);
        } else {
          auto elseBody = std::make_shared<AST::Block>();
          elseBody->nodes.push_back(parseFactor());
          _if->elseBody = elseBody;
        }
      }
    }

    return _if;
  }

  std::shared_ptr<AST::Number> Parser::parseNumber() {
    auto number = static_cast<Token::Number *>(m_lexer.token(Token::Type::NUMBER));
    auto ast = std::make_shared<AST::Number>(number->value);
    ast->loc = number->loc;
    ast->typeInfo = m_types["Int"];
    return ast;
  }

  std::shared_ptr<AST> Parser::parseID() {
    auto id = *static_cast<Token::ID *>(m_lexer.token(Token::Type::ID));

    if (id.name == "if") {
      return parseIf();
    }

    std::shared_ptr<AST> ast, ref;
    if ((ref = m_scope->get(id.name, false)) != nullptr && ref->type == AST::Type::FunctionArgument) {
      ast = ref;
    } else {
      unsigned uid;
      auto it = std::find(m_ast->strings.begin(), m_ast->strings.end(), id.name);
      if (it != m_ast->strings.end()) {
        uid = it - m_ast->strings.begin();
      } else {
        uid = str_uid++;
        m_ast->strings.push_back(id.name);
      }

      ast = std::make_shared<AST::ID>(m_ast->strings[uid], uid);
      ast->loc = id.loc;

      if ((ref = m_scope->get(id.name)) && !m_scope->isInCurrentScope(id.name)) {
        if (ref->type == AST::Type::FunctionArgument) {
          AST::asFunctionArgument(ref)->isCaptured = true;
          m_scope->scopeFor(id.name)->isRequired = true;
          m_scope->capturesScope = true;
        }
      }
    }

    while (true) {
      if (m_lexer.token()->type == Token::Type::TYPE) {
        parseTypeInfo(std::move(ast));
        return nullptr;
      } else if (m_lexer.token()->type == Token::Type::L_PAREN) {
        ast = parseCall(std::move(ast));
      } else if (m_lexer.token()->type == Token::Type::L_BRACE) {
        assert(ast->type == AST::Type::Call);
        auto call = AST::asCall(ast);
        ast = parseFunction(std::move(call));
      } else {
        break;
      }
    }

    if (ast->type == AST::Type::Call) {
      typeCheck(AST::asCall(ast));
    }

    return ast;
  }

  std::shared_ptr<AST::Function> Parser::parseFunction(std::shared_ptr<AST::Call> &&call) {
    assert(call->callee->type == AST::Type::ID);

    auto fn = std::make_shared<AST::Function>();
    fn->name = AST::asID(call->callee);
    if (!(fn->typeInfo = m_typeInfo[fn->name->name])) {
      fprintf(stderr, "Defining function `%s` that does not have type information\n", fn->name->name.c_str());
      throw std::runtime_error("Missing type infomation");
    }

    m_scope->set(fn->name->name, fn);
    m_scope->isRequired = true;

    m_scope = m_scope->create();

    unsigned i = 0;
    for (auto arg : call->arguments) {
      std::string argName;
      if (arg->type == AST::Type::ID) {
        argName = AST::asID(arg)->name;
      } else if (arg->type == AST::Type::FunctionArgument) {
        argName = AST::asFunctionArgument(arg)->name;
      } else {
        perror("Can't handle argument type on function declaration");
        throw;
      }

      auto fnArg = std::make_shared<AST::FunctionArgument>(argName, i);
      fnArg->typeInfo = fn->getTypeInfo()->types[i++];
      fn->arguments.push_back(fnArg);
      m_scope->set(argName, fnArg);
    }

    m_lexer.ensure(Token::Type::L_BRACE);
    fn->body = parseBlock(Token::Type::R_BRACE);
    fn->loc.start = fn->name->loc.start;
    fn->loc.end = m_lexer.token(Token::Type::R_BRACE)->loc.end;

    m_scope = m_scope->restore();

    return fn;
  }

  std::shared_ptr<AST::String> Parser::parseString() {
    auto string = static_cast<Token::String *>(m_lexer.token(Token::Type::STRING));

    int uid;
    auto it = std::find(m_ast->strings.begin(), m_ast->strings.end(), string->value);
    if (it != m_ast->strings.end()) {
      uid = it - m_ast->strings.begin();
    } else {
      uid = str_uid++;
      m_ast->strings.push_back(string->value);
    }

    auto ast =  std::make_shared<AST::String>(m_ast->strings[uid], uid);
    ast->loc = string->loc;
    ast->typeInfo = m_types["String"];
    return ast;
  }

  std::shared_ptr<AST::Call> Parser::parseCall(std::shared_ptr<AST> &&callee) {
    auto start = callee->loc.start;

    m_lexer.ensure(Token::Type::L_PAREN);

    auto call = std::make_shared<AST::Call>();
    call->callee = callee;
    call->typeInfo = new TypeChain();

    while (m_lexer.token()->type != Token::Type::R_PAREN) {
      auto argument = parseFactor();
      call->getTypeInfo()->types.push_back(argument->typeInfo);
      call->arguments.push_back(argument);
      if (m_lexer.token()->type != Token::Type::R_PAREN) {
        m_lexer.ensure(Token::Type::COMMA);
      }
    }

    auto end = m_lexer.token(Token::Type::R_PAREN)->loc.end;
    call->loc = { start, end };

    return call;
  }

  void Parser::parseTypeInfo(std::shared_ptr<AST> &&target) {
    m_lexer.ensure(Token::Type::TYPE);

    TypeChain *typeInfo = new TypeChain();
    do {
      auto typeString = AST::asID(parseID())->name;
      auto type = m_types[typeString];
      if (!type) {
        throw std::runtime_error("Undefined type");
      }
      typeInfo->types.push_back(type);
    } while (m_lexer.skip(Token::Type::ARROW));
    m_typeInfo[AST::asID(target)->name] = typeInfo;
  }

  void Parser::typeCheck(std::shared_ptr<AST::Call> &&call) {
    TypeChain *typeInfo;
    if (call->callee->type == AST::Type::ID) {
      auto calleeName = AST::asID(call->callee)->name;
      auto it = m_typeInfo.find(calleeName);
      if (it == m_typeInfo.end()) {
        fprintf(stderr, "Missing type information for `%s`\n", calleeName.c_str());
        throw;
      }
      typeInfo = it->second;

      if (call->arguments.size() != typeInfo->types.size() - 1) {
        fprintf(stderr, "Invalid type");
        throw;
      }

      for (unsigned i = 0; i < typeInfo->types.size() - 1; i++) {
        Type* expected = typeInfo->types[i];
        Type* actual = call->getTypeInfo()->types[i];

        if (actual != expected) {
          fprintf(stderr, "Expected `%s` but got `%s`\n", expected->toString().c_str(), actual->toString().c_str());
          throw;
        }
      }
    }
  }
}
