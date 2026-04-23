*&---------------------------------------------------------------------*
*& Report  ZAUTH_TO_SAILPOINT
*& Demo: lançamento de fatura com verificação de acesso em SailPoint.
*&
*& Instead of a local AUTHORITY-CHECK, the program asks SailPoint ISC
*& whether the caller identity already has the "Contas a Pagar /
*& Accounts Payable" access profile assigned.
*&
*& Flow (100% code, no dynpros to paint - technical keywords in EN,
*&       user-facing text in PT):
*&
*&   1. SELECTION-SCREEN: Empresa / Fornecedor / Referência /
*&                        Valor / Moeda
*&   2. F8 -> START-OF-SELECTION
*&        - OAuth (client_credentials)
*&        - GET /v3/search : identity & accessProfiles.id
*&        - match  -> MESSAGE 'S'  "Fatura lançada"
*&        - miss   -> POPUP_GET_VALUES 3 fields:
*&                      Justificação
*&                      Data de início  (Madrid TZ, hoje)
*&                      Data de fim     (hoje + 30 dias)
*&                    -> confirm -> POST /v3/access-requests
*&                                  with comment + removeDate
*&                    -> POPUP_TO_INFORM with HTTP result / request id
*&---------------------------------------------------------------------*
REPORT zauth_to_sailpoint.

*----------------------------------------------------------------------*
* Constants (in prod: read from config table or STRUST/SSF)
*----------------------------------------------------------------------*
CONSTANTS:
  c_tenant_api  TYPE string VALUE 'https://company21824-poc.api.identitynow-demo.com',
  c_client_id   TYPE string VALUE '43a4f8cd5fca43e1ac891ac9f5b9d711',
  c_client_sec  TYPE string VALUE '<<INJECT_AT_RUNTIME>>',
  c_identity_id TYPE string VALUE '2c9180857aaaaaaaaaaaaaaaaaaaaaaa',
  c_ap_id       TYPE string VALUE '2c9180857bbbbbbbbbbbbbbbbbbbbbbb',
  c_ap_name     TYPE string VALUE 'Contas a Pagar',
  c_tz_madrid   TYPE timezone VALUE 'CET'.

*----------------------------------------------------------------------*
* Selection screen (cabeçalho tipo FB60)
*----------------------------------------------------------------------*
SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE TEXT-t01.
  PARAMETERS:
    p_bukrs TYPE bukrs DEFAULT '1000'         OBLIGATORY,
    p_lifnr TYPE lifnr DEFAULT '0000100001'   OBLIGATORY,
    p_xblnr TYPE xblnr DEFAULT 'INV-2026-0423',
    p_wrbtr TYPE wrbtr DEFAULT '1250.00',
    p_waers TYPE waers DEFAULT 'EUR'.
SELECTION-SCREEN END OF BLOCK b1.

DATA: gv_token      TYPE string,
      gv_has_access TYPE abap_bool,
      gv_reqid      TYPE string,
      gv_http       TYPE i.

*----------------------------------------------------------------------*
START-OF-SELECTION.

  PERFORM get_oauth_token CHANGING gv_token.
  IF gv_token IS INITIAL.
    PERFORM inform USING 'SailPoint'
                         'Falha na autenticação OAuth.'
                         'Verificar client_id / client_secret / tenant.'
                         '' ''.
    RETURN.
  ENDIF.

  PERFORM check_identity_has_access USING    gv_token
                                    CHANGING gv_has_access.

  IF gv_has_access = abap_true.
    MESSAGE |Fatura { p_xblnr } lançada na empresa { p_bukrs } | &&
            |(fornecedor { p_lifnr }, { p_wrbtr } { p_waers }).|
            TYPE 'S'.
    RETURN.
  ENDIF.

  PERFORM ask_and_submit_request USING gv_token.

*&---------------------------------------------------------------------*
*&  Popup: ask for justification + dates, then submit to SailPoint
*&---------------------------------------------------------------------*
FORM ask_and_submit_request USING iv_token TYPE string.

  DATA: lt_fields    TYPE TABLE OF sval,
        ls_field     TYPE sval,
        lv_rc        TYPE c LENGTH 1,
        lv_ts        TYPE timestamp,
        lv_today     TYPE d,
        lv_end       TYPE d,
        lv_time      TYPE t,
        lv_comment   TYPE string,
        lv_start_str TYPE string,
        lv_end_iso   TYPE string.

  " Default dates in Madrid timezone (CET / CEST with DST)
  GET TIME STAMP FIELD lv_ts.
  CONVERT TIME STAMP lv_ts TIME ZONE c_tz_madrid
    INTO DATE lv_today TIME lv_time.
  lv_end = lv_today + 30.

  " Field 1: Justificação
  CLEAR ls_field.
  ls_field-tabname   = 'BAPIRET2'.
  ls_field-fieldname = 'MESSAGE'.
  ls_field-fieldtext = 'Justificação'.
  ls_field-value     = |Lançamento FB60 - necessário acesso { c_ap_name } | &&
                       |para empresa { p_bukrs }|.
  APPEND ls_field TO lt_fields.

  " Field 2: Data de início
  CLEAR ls_field.
  ls_field-tabname   = 'BKPF'.
  ls_field-fieldname = 'BUDAT'.
  ls_field-fieldtext = 'Data de início'.
  ls_field-value     = lv_today.
  APPEND ls_field TO lt_fields.

  " Field 3: Data de fim
  CLEAR ls_field.
  ls_field-tabname   = 'BKPF'.
  ls_field-fieldname = 'VALUT'.
  ls_field-fieldtext = 'Data de fim'.
  ls_field-value     = lv_end.
  APPEND ls_field TO lt_fields.

  CALL FUNCTION 'POPUP_GET_VALUES'
    EXPORTING
      popup_title     = |Pedido de acesso - { c_ap_name }|
      start_column    = 10
      start_row       = 5
    IMPORTING
      returncode      = lv_rc
    TABLES
      fields          = lt_fields
    EXCEPTIONS
      error_in_fields = 1
      OTHERS          = 2.

  IF sy-subrc <> 0 OR lv_rc = 'A'.
    RETURN.
  ENDIF.

  READ TABLE lt_fields INTO ls_field INDEX 1.
  lv_comment = ls_field-value.
  READ TABLE lt_fields INTO ls_field INDEX 2.
  lv_today   = ls_field-value.
  READ TABLE lt_fields INTO ls_field INDEX 3.
  lv_end     = ls_field-value.

  lv_start_str = |{ lv_today+0(4) }-{ lv_today+4(2) }-{ lv_today+6(2) }|.
  lv_end_iso   = |{ lv_end+0(4)   }-{ lv_end+4(2)   }-{ lv_end+6(2)   }T00:00:00.000Z|.

  PERFORM submit_request USING    iv_token
                                  lv_comment
                                  lv_start_str
                                  lv_end_iso
                         CHANGING gv_reqid gv_http.

  IF gv_http = 200 OR gv_http = 201 OR gv_http = 202.
    PERFORM inform USING 'SailPoint'
                         |Pedido aceite (HTTP { gv_http }).|
                         |ID do pedido: { gv_reqid }|
                         |Identidade: { c_identity_id }|
                         |Válido até: { lv_end_iso }|.
  ELSEIF gv_http = 429.
    PERFORM inform USING 'SailPoint'
                         'Limite de pedidos excedido (HTTP 429).'
                         'Cabeçalho Retry-After indica o back-off.'
                         'Pode ter disparado workflow de anomalia.'
                         ''.
  ELSE.
    PERFORM inform USING 'SailPoint'
                         |Pedido rejeitado (HTTP { gv_http }).|
                         'Ver SM21 / ST22 para resposta completa.'
                         '' ''.
  ENDIF.
ENDFORM.

*&---------------------------------------------------------------------*
FORM inform USING iv_title TYPE string
                  iv_l1    TYPE string
                  iv_l2    TYPE string
                  iv_l3    TYPE string
                  iv_l4    TYPE string.
  DATA: lv_t TYPE char70,
        lv_a TYPE char70,
        lv_b TYPE char70,
        lv_c TYPE char70,
        lv_d TYPE char70.
  lv_t = iv_title. lv_a = iv_l1. lv_b = iv_l2.
  lv_c = iv_l3.    lv_d = iv_l4.
  CALL FUNCTION 'POPUP_TO_INFORM'
    EXPORTING titel = lv_t
              txt1  = lv_a
              txt2  = lv_b
              txt3  = lv_c
              txt4  = lv_d.
ENDFORM.

*======================================================================*
*  SailPoint ISC helpers
*======================================================================*
FORM get_oauth_token CHANGING cv_token TYPE string.
  DATA: lo_http TYPE REF TO if_http_client,
        lv_url  TYPE string,
        lv_body TYPE string,
        lv_resp TYPE string,
        lv_code TYPE i.

  lv_url = |{ c_tenant_api }/oauth/token|.

  cl_http_client=>create_by_url(
    EXPORTING url    = lv_url
    IMPORTING client = lo_http ).

  lo_http->request->set_method( 'POST' ).
  lo_http->request->set_header_field(
    name = 'Content-Type' value = 'application/x-www-form-urlencoded' ).

  lv_body = |grant_type=client_credentials|      &&
            |&client_id={ c_client_id }|         &&
            |&client_secret={ c_client_sec }|.
  lo_http->request->set_cdata( lv_body ).

  lo_http->send( ).
  lo_http->receive( ).
  lo_http->response->get_status( IMPORTING code = lv_code ).
  lv_resp = lo_http->response->get_cdata( ).

  IF lv_code <> 200.
    CLEAR cv_token.
    RETURN.
  ENDIF.

  " Crude JSON parse. In real Z code use /UI2/CL_JSON.
  FIND REGEX '"access_token"\s*:\s*"([^"]+)"'
       IN lv_resp SUBMATCHES cv_token.
ENDFORM.

*----------------------------------------------------------------------*
*  Query SailPoint: is the access profile already assigned to identity?
*  POST /v3/search   indices=identities
*    query: id:{identity_id} AND accessProfiles.id:{ap_id}
*  Non-empty result -> access granted.
*----------------------------------------------------------------------*
FORM check_identity_has_access USING    iv_token      TYPE string
                               CHANGING cv_has_access TYPE abap_bool.
  DATA: lo_http TYPE REF TO if_http_client,
        lv_url  TYPE string,
        lv_body TYPE string,
        lv_resp TYPE string,
        lv_code TYPE i.

  CLEAR cv_has_access.
  lv_url = |{ c_tenant_api }/v3/search|.

  lv_body =
    |\{| &&
      |"indices":["identities"],| &&
      |"query":\{| &&
        |"query":"id:{ c_identity_id } AND accessProfiles.id:{ c_ap_id }"| &&
      |\}| &&
    |\}|.

  cl_http_client=>create_by_url(
    EXPORTING url    = lv_url
    IMPORTING client = lo_http ).

  lo_http->request->set_method( 'POST' ).
  lo_http->request->set_header_field(
    name = 'Authorization' value = |Bearer { iv_token }| ).
  lo_http->request->set_header_field(
    name = 'Content-Type'  value = 'application/json' ).
  lo_http->request->set_cdata( lv_body ).

  lo_http->send( ).
  lo_http->receive( ).
  lo_http->response->get_status( IMPORTING code = lv_code ).
  lv_resp = lo_http->response->get_cdata( ).

  IF lv_code <> 200.
    RETURN.
  ENDIF.

  " Match means the search index returned the identity
  " with that access profile. An empty JSON array "[]" means no.
  IF lv_resp CS |"id":"{ c_identity_id }"|.
    cv_has_access = abap_true.
  ENDIF.
ENDFORM.

*----------------------------------------------------------------------*
*  POST /v3/access-requests with justification + removeDate
*----------------------------------------------------------------------*
FORM submit_request USING    iv_token   TYPE string
                             iv_comment TYPE string
                             iv_start   TYPE string
                             iv_end_iso TYPE string
                    CHANGING cv_reqid   TYPE string
                             cv_http    TYPE i.
  DATA: lo_http TYPE REF TO if_http_client,
        lv_url  TYPE string,
        lv_body TYPE string,
        lv_resp TYPE string,
        lv_cmt  TYPE string.

  " Minimal JSON escape for user-supplied justification
  lv_cmt = iv_comment.
  REPLACE ALL OCCURRENCES OF '\' IN lv_cmt WITH '\\'.
  REPLACE ALL OCCURRENCES OF '"' IN lv_cmt WITH '\"'.
  REPLACE ALL OCCURRENCES OF cl_abap_char_utilities=>cr_lf   IN lv_cmt WITH ' '.
  REPLACE ALL OCCURRENCES OF cl_abap_char_utilities=>newline IN lv_cmt WITH ' '.

  lv_url = |{ c_tenant_api }/v3/access-requests|.

  lv_body =
    |\{| &&
      |"requestedFor":["{ c_identity_id }"],| &&
      |"requestType":"GRANT_ACCESS",| &&
      |"requestedItems":[\{| &&
        |"type":"ACCESS_PROFILE",| &&
        |"id":"{ c_ap_id }",| &&
        |"comment":"{ lv_cmt }",| &&
        |"removeDate":"{ iv_end_iso }",| &&
        |"clientMetadata":\{| &&
          |"sourceSystem":"SAP-PRD",| &&
          |"tcode":"FB60",| &&
          |"accessStartDate":"{ iv_start }",| &&
          |"bukrs":"{ p_bukrs }",| &&
          |"lifnr":"{ p_lifnr }",| &&
          |"xblnr":"{ p_xblnr }",| &&
          |"triggeredBy":"ZAUTH_TO_SAILPOINT"| &&
        |\}| &&
      |\}]| &&
    |\}|.

  cl_http_client=>create_by_url(
    EXPORTING url    = lv_url
    IMPORTING client = lo_http ).

  lo_http->request->set_method( 'POST' ).
  lo_http->request->set_header_field(
    name = 'Authorization' value = |Bearer { iv_token }| ).
  lo_http->request->set_header_field(
    name = 'Content-Type'  value = 'application/json' ).
  lo_http->request->set_cdata( lv_body ).

  lo_http->send( ).
  lo_http->receive( ).
  lo_http->response->get_status( IMPORTING code = cv_http ).
  lv_resp = lo_http->response->get_cdata( ).

  CLEAR cv_reqid.
  IF cv_http = 200 OR cv_http = 201 OR cv_http = 202.
    FIND REGEX '"id"\s*:\s*"([^"]+)"'
         IN lv_resp SUBMATCHES cv_reqid.
  ENDIF.
ENDFORM.
