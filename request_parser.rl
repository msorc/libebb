#include "request_parser.h"

#include <stdio.h>
#include <assert.h>
#include <string.h>
#include <stdlib.h> /* for the default methods */

#define TRUE 1
#define FALSE 0
#define MIN(a,b) (a < b ? a : b)

#define REMAINING (pe - p)
#define CURRENT (parser->current_request)
#define CONTENT_LENGTH (parser->current_request->content_length)

#define eip_empty(parser) (parser->eip_stack[0] == NULL)

static void eip_push
  ( ebb_request_parser *parser
  , ebb_element *element
  )
{
  int i = 0;
  /* NO BOUNDS CHECKING - LIVING ON THE EDGE! */
  for(i = 0; parser->eip_stack[i] != NULL; i++) {;}
  //printf("push! (stack size before: %d)\n", i);
  parser->eip_stack[i] = element;
}

static ebb_element* eip_pop
  ( ebb_request_parser *parser
  )
{
  int i;
  ebb_element *top = NULL;
  assert( ! eip_empty(parser) ); 
  /* NO BOUNDS CHECKING - LIVING ON THE EDGE! */
  for(i = 0; parser->eip_stack[i] != NULL; i++) {;}
  //printf("pop! (stack size before: %d)\n", i);
  top = parser->eip_stack[i-1];
  parser->eip_stack[i-1] = NULL;
  return top;
}


%%{
  machine ebb_request_parser;

  action mark {
    //printf("mark!\n");
    eip = parser->new_element(parser->data);
    eip->base = p;
    eip_push(parser, eip);
  }

  # TODO REMOVE!!! arg! should i use the -d option in ragel?
  action mmark {
    //printf("mmark!\n");
    eip = parser->new_element(parser->data);
    eip->base = p;
    eip_push(parser, eip);
  }

  action write_field { 
    //printf("write_field!\n");
    assert(parser->header_field_element == NULL);  
    eip = eip_pop(parser);
    last = ebb_element_last(eip);
    last->len = p - last->base;
    parser->header_field_element = eip;
    assert(eip_empty(parser) && "eip_stack must be empty after header field");
  }

  action write_value {
    //printf("write_value!\n");
    assert(parser->header_field_element != NULL);  

    eip = eip_pop(parser);
    last = ebb_element_last(eip);
    last->len = p - last->base;  

    if(parser->header_handler)
      parser->header_handler( CURRENT
                            , parser->header_field_element
                            , eip
                            , parser->data
                            );
    free_element(parser->header_field_element);
    free_element(eip);
    eip = parser->header_field_element = NULL;
  }

  action request_uri { 
    //printf("request uri\n");
    eip = eip_pop(parser);
    last = ebb_element_last(eip);
    last->len = p - last->base;  
    if(parser->request_uri)
      parser->request_uri(CURRENT, eip, parser->data);
    free_element(eip);
  }

  action fragment { 
    //printf("fragment\n");
    eip = eip_pop(parser);
    last = ebb_element_last(eip);
    last->len = p - last->base;  
    if(parser->fragment)
      parser->fragment(CURRENT, eip, parser->data);
    free_element(eip);
  }

  action query_string { 
    //printf("query  string\n");
    eip = eip_pop(parser);
    last = ebb_element_last(eip);
    last->len = p - last->base;  
    if(parser->query_string)
      parser->query_string(CURRENT, eip, parser->data);
    free_element(eip);
  }

  action request_path {
    //printf("request path\n");
    eip = eip_pop(parser);
    last = ebb_element_last(eip);
    last->len = p - last->base;  
    if(parser->request_path)
      parser->request_path(CURRENT, eip, parser->data);
    free_element(eip);
  }

  action request_method { 
    //printf("request method\n");
    eip = eip_pop(parser);
    last = ebb_element_last(eip);
    last->len = p - last->base;
    if(parser->request_method)
      parser->request_method(CURRENT, eip, parser->data);
    free_element(eip);
  }

  action content_length {
    //printf("content_length!\n");
    CURRENT->content_length *= 10;
    CURRENT->content_length += *p - '0';
  }

  action use_identity_encoding {
    //printf("use identity encoding\n");
    CURRENT->transfer_encoding = EBB_IDENTITY;
  }

  action use_chunked_encoding {
    //printf("use chunked encoding\n");
    CURRENT->transfer_encoding = EBB_CHUNKED;
  }

  action expect_continue {
    CURRENT->expect_continue = TRUE;
  }

  action trailer {
    //printf("trailer\n");
    /* not implemenetd yet. (do requests even have trailing headers?) */
  }


  action version_major {
    CURRENT->version_major *= 10;
    CURRENT->version_major += *p - '0';
  }

  action version_minor {
    CURRENT->version_minor *= 10;
    CURRENT->version_minor += *p - '0';
  }

  action add_to_chunk_size {
    //printf("add to chunk size\n");
    parser->chunk_size *= 16;
    /* XXX: this can be optimized slightly */
    if( 'A' <= *p && *p <= 'F') 
      parser->chunk_size += *p - 'A' + 10;
    else if( 'a' <= *p && *p <= 'f') 
      parser->chunk_size += *p - 'a' + 10;
    else if( '0' <= *p && *p <= '9') 
      parser->chunk_size += *p - '0';
    else  
      assert(0 && "bad hex char");
  }

  action skip_chunk_data {
    //printf("skip chunk data\n");
    //printf("chunk_size: %d\n", parser->chunk_size);
    if(parser->chunk_size > REMAINING) {
      parser->eating = TRUE;
      parser->body_handler(CURRENT, p, REMAINING, parser->data);
      parser->chunk_size -= REMAINING;
      fhold; 
      fbreak;
    } else {
      parser->body_handler(CURRENT, p, parser->chunk_size, parser->data);
      p += parser->chunk_size;
      parser->chunk_size = 0;
      parser->eating = FALSE;
      fhold; 
      fgoto chunk_end; 
    }
  }

  action end_chunked_body {
    //printf("end chunked body\n");
    if(parser->request_complete)
      parser->request_complete(CURRENT, parser->data);
    fret; // goto Request; 
  }

  action start_req {
    if(CURRENT && CURRENT->free)
      CURRENT->free(CURRENT);
    CURRENT = parser->new_request_info(parser->data);
  }

  action body_logic {
    if(CURRENT->transfer_encoding == EBB_CHUNKED) {
      fcall ChunkedBody;
    } else {
      /*
       * EAT BODY
       * this is very ugly. sorry.
       *
       */
      if( CURRENT->content_length == 0) {

        if( parser->request_complete )
          parser->request_complete(CURRENT, parser->data);


      } else if( CURRENT->content_length < REMAINING ) {
        /* 
         * 
         * FINISH EATING THE BODY. there is still more 
         * on the buffer - so we just let it continue
         * parsing after we're done
         *
         */
        p += 1;
        if( parser->body_handler )
          parser->body_handler(CURRENT, p, CURRENT->content_length, parser->data); 

        p += CURRENT->content_length;
        CURRENT->body_read = CURRENT->content_length;

        assert(0 <= REMAINING);

        if( parser->request_complete )
          parser->request_complete(CURRENT, parser->data);

        fhold;

      } else {
        /* 
         * The body is larger than the buffer
         * EAT REST OF BUFFER
         * there is still more to read though. this will  
         * be handled on the next invokion of ebb_request_parser_execute
         * right before we enter the state machine. 
         *
         */
        p += 1;
        size_t eat = REMAINING;

        if( parser->body_handler && eat > 0)
          parser->body_handler(CURRENT, p, eat, parser->data); 

        p += eat;
        CURRENT->body_read += eat;
        CURRENT->eating_body = TRUE;
        //printf("eating body!\n");

        assert(CURRENT->body_read < CURRENT->content_length);
        assert(REMAINING == 0);
        
        fhold; fbreak;  
      }
    }
  }

#
##
###
#### HTTP/1.1 STATE MACHINE
###
##   RequestHeaders and character types are from
#    Zed Shaw's beautiful Mongrel parser.

  CRLF = "\r\n";

# character types
  CTL = (cntrl | 127);
  safe = ("$" | "-" | "_" | ".");
  extra = ("!" | "*" | "'" | "(" | ")" | ",");
  reserved = (";" | "/" | "?" | ":" | "@" | "&" | "=" | "+");
  unsafe = (CTL | " " | "\"" | "#" | "%" | "<" | ">");
  national = any -- (alpha | digit | reserved | extra | safe | unsafe);
  unreserved = (alpha | digit | safe | extra | national);
  escape = ("%" xdigit xdigit);
  uchar = (unreserved | escape);
  pchar = (uchar | ":" | "@" | "&" | "=" | "+");
  tspecials = ("(" | ")" | "<" | ">" | "@" | "," | ";" | ":" | "\\" | "\"" | "/" | "[" | "]" | "?" | "=" | "{" | "}" | " " | "\t");

# elements
  token = (ascii -- (CTL | tspecials));
#  qdtext = token -- "\""; 
#  quoted_pair = "\" ascii;
#  quoted_string = "\"" (qdtext | quoted_pair )* "\"";

#  headers
  scheme = ( alpha | digit | "+" | "-" | "." )* ;
  absolute_uri = (scheme ":" (uchar | reserved )*);
  path = ( pchar+ ( "/" pchar* )* ) ;
  query = ( uchar | reserved )* >mark %query_string ;
  param = ( pchar | "/" )* ;
  params = ( param ( ";" param )* ) ;
  rel_path = ( path? (";" params)? ) ;
  absolute_path = ( "/"+ rel_path ) >mmark %request_path ("?" query)?;
  Request_URI = ( "*" | absolute_uri | absolute_path ) >mark %request_uri;
  Fragment = ( uchar | reserved )* >mark %fragment;
  Method = ( upper | digit | safe ){1,20} >mark %request_method;
  http_number = (digit+ $version_major "." digit+ $version_minor);
  HTTP_Version = ( "HTTP/" http_number );

  field_name = ( token -- ":" )+;
  field_value = ((any - " ") any*)?;

  head_sep = ":" " "*;
  message_header = field_name head_sep field_value :> CRLF;

  cl = "Content-Length"i %write_field  head_sep
       digit+ >mark $content_length %write_value;

  te = "Transfer-Encoding"i %write_field %use_chunked_encoding head_sep
       "identity"i >mark %use_identity_encoding %write_value;

  expect = "Expect"i %write_field head_sep
       "100-continue"i >mark %expect_continue %write_value;

  t =  "Trailer"i %write_field head_sep
        field_value >mark %trailer %write_value;

  rest = (field_name %write_field head_sep field_value >mark %write_value);

  header  = cl     @(headers,4)
          | te     @(headers,4)
          | expect @(headers,4)
          | t      @(headers,4)
          | rest   @(headers,1)
          ;

  Request_Line = ( Method " " Request_URI ("#" Fragment)? " " HTTP_Version CRLF ) ;
  RequestHeader = Request_Line (header >mark :> CRLF)* :> CRLF;

# chunked message
  trailing_headers = message_header*;
  #chunk_ext_val   = token | quoted_string;
  chunk_ext_val = token*;
  chunk_ext_name = token*;
  chunk_extension = ( ";" " "* chunk_ext_name ("=" chunk_ext_val)? )*;
  last_chunk = "0"+ chunk_extension CRLF;
  chunk_size = (xdigit* [1-9a-fA-F] xdigit*) $add_to_chunk_size;
  chunk_end  = CRLF;
  chunk_body = any >skip_chunk_data;
  chunk_begin = chunk_size chunk_extension CRLF;
  chunk = chunk_begin chunk_body chunk_end;
  ChunkedBody := chunk* last_chunk trailing_headers CRLF @end_chunked_body;

  Request = RequestHeader >start_req @body_logic;

  main := Request+; # sequence of requests (for keep-alive)
}%%

%% write data;

#define COPYSTACK(dest, src)  for(i = 0; i < EBB_RAGEL_STACK_SIZE; i++) { dest[i] = src[i]; }

/* calls the element's free for each item in the list */
static void free_element
  ( ebb_element *element
  )
{
  if(element) {
    free_element(element->next);
    element->next = NULL;
    if(element->free) 
      element->free(element);
  }
}

static ebb_element *default_new_element
  ( void *data
  )
{
  ebb_element *element = malloc(sizeof(ebb_element));
  ebb_element_init(element);
  element->free = (void (*)(ebb_element*))free;
  return element; 
}

static ebb_request_info* default_new_request_info
  ( void *data
  )
{
  ebb_request_info *request_info = malloc(sizeof(ebb_request_info));
  ebb_request_info_init(request_info);
  request_info->free = (void (*)(ebb_request_info*))free;
  return request_info; 
}

void ebb_request_parser_init
  ( ebb_request_parser *parser
  ) 
{
  int i;

  int cs = 0;
  int top = 0;
  int stack[EBB_RAGEL_STACK_SIZE];
  %% write init;
  parser->cs = cs;
  parser->top = top;
  COPYSTACK(parser->stack, stack);

  parser->chunk_size = 0;
  parser->eating = 0;
  
  parser->eip_stack[0] = NULL;
  parser->current_request = NULL;
  parser->header_field_element = NULL;

  parser->new_element = default_new_element;
  parser->new_request_info = default_new_request_info;

  parser->request_complete = NULL;
  parser->body_handler = NULL;
  parser->header_handler = NULL;
  parser->request_method = NULL;
  parser->request_uri = NULL;
  parser->fragment = NULL;
  parser->request_path = NULL;
  parser->query_string = NULL;
}


/** exec **/
size_t ebb_request_parser_execute
  ( ebb_request_parser *parser
  , const char *buffer
  , size_t len
  )
{
  ebb_element *eip, *last; 
  const char *p, *pe;
  int i, cs = parser->cs;

  int top = parser->top;
  int stack[EBB_RAGEL_STACK_SIZE];
  COPYSTACK(stack, parser->stack);

  assert(parser->new_element && "undefined callback");
  assert(parser->new_request_info && "undefined callback");

  p = buffer;
  pe = buffer+len;

  if(0 < parser->chunk_size && parser->eating) {
    /*
     *
     * eat chunked body
     * 
     */
    //printf("eat chunk body (before parse)\n");
    size_t eat = MIN(len, parser->chunk_size);
    if(eat == parser->chunk_size) {
      parser->eating = FALSE;
    }
    parser->body_handler(CURRENT, p, eat, parser->data);
    p += eat;
    parser->chunk_size -= eat;
    //printf("eat: %d\n", eat);
  } else if( parser->current_request && 
             CURRENT->eating_body ) {
    /*
     *
     * eat normal body
     * 
     */
    //printf("eat normal body (before parse)\n");
    size_t eat = MIN(len, CURRENT->content_length - CURRENT->body_read);

    parser->body_handler(CURRENT, p, eat, parser->data);
    p += eat;
    CURRENT->body_read += eat;

    if(CURRENT->body_read == CURRENT->content_length) {
      if(parser->request_complete)
        parser->request_complete(CURRENT, parser->data);
      CURRENT->eating_body = FALSE;
    }
  }



  /* each on the eip stack gets expanded */
  for(i = 0; parser->eip_stack[i] != NULL; i++) {
    last = ebb_element_last(parser->eip_stack[i]);
    last->next = parser->new_element(parser->data);
    last->next->base = buffer;
  }

  %% write exec;

  parser->cs = cs;
  parser->top = top;
  COPYSTACK(parser->stack, stack);


  /* each on the eip stack gets len */
  for(i = 0; parser->eip_stack[i] != NULL; i++) {
    last = ebb_element_last(parser->eip_stack[i]);
    last->len = pe - last->base;
  }

  assert(p <= pe && "buffer overflow after parsing execute");

  return(p - buffer);
}

int ebb_request_parser_has_error
  ( ebb_request_parser *parser
  ) 
{
  return parser->cs == ebb_request_parser_error;
}

int ebb_request_parser_is_finished
  ( ebb_request_parser *parser
  ) 
{
  return parser->cs == ebb_request_parser_first_final;
}

void ebb_request_info_init
  ( ebb_request_info *request
  )
{
  request->expect_continue = FALSE;
  request->eating_body = 0;
  request->body_read = 0;
  request->content_length = 0;
  request->version_major = 0;
  request->version_minor = 0;
  request->transfer_encoding = EBB_IDENTITY;
  request->free = NULL;
}

void ebb_element_init
  ( ebb_element *element
  ) 
{
  element->base = NULL;
  element->len  = -1;
  element->next = NULL;
  element->free = NULL;
}

ebb_element* ebb_element_last
  ( ebb_element *element
  )
{
  /* TODO: currently a linked list but could be 
   * done with a circular ll for * O(1) access
   * probably not a big deal as it is since these 
   * never get very long 
   */
  for( ; element->next; element = element->next) {;}
  return element;
}

size_t ebb_element_len
  ( ebb_element *element
  )
{
  size_t len; 
  for(len = 0; element; element = element->next)
    len += element->len;
  return len;
}

void ebb_element_strcpy
  ( ebb_element *element
  , char *dest
  )
{
  dest[0] = '\0';
  for( ; element; element = element->next) 
    strncat(dest, element->base, element->len);
}

void ebb_element_printf
  ( ebb_element *element
  , const char *format
  )
{
  char str[1000];
  ebb_element_strcpy(element, str);
  printf(format, str);
}

