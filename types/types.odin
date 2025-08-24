package types

import "core:io"
import "core:mem"

Error :: union #shared_nil {
	io.Error,
	Fcgi_Error,
	Serialize_Error,
	mem.Allocator_Error,
}

Fcgi_Error :: enum {
	None,
	Unknown_Record_Type,
	Invalid_Record,
}

Serialize_Error :: enum {
	None,
	Key_Too_Large,
	Value_Too_Large,
}

Request :: struct {
	id:            u16,
	role:          Role,
	flags:         bit_set[Request_Flag;u8],
	params:        map[string]string,
	stdin:         [dynamic]u8,
	is_get_values: bool,
}

Header :: struct #packed {
	version:           u8,
	type:              Record_Type,
	request_id_b1:     u8,
	request_id_b0:     u8,
	content_length_b1: u8,
	content_length_b0: u8,
	padding_length:    u8,
	reserved:          u8,
}

Record_Type :: enum u8 {
	Begin_Request     = 1,
	Abort_Request     = 2,
	End_Request       = 3,
	Params            = 4,
	Stdin             = 5,
	Stdout            = 6,
	Stderr            = 7,
	Data              = 8,
	Get_Values        = 9,
	Get_Values_Result = 10,
	Unknown_Type      = 11,
}

Record :: struct {
	header: Header,
	body:   Body,
}

Body :: union {
	Begin_Request_Body,
	End_Request_Body,
	Unknown_Type_Body,
	Raw_Body,
}

Begin_Request_Body :: struct #packed {
	role_b1:  u8,
	role_b0:  u8,
	flags:    bit_set[Request_Flag;u8],
	reserved: [5]u8,
}

Request_Flag :: enum u8 {
	Keep_Conn = 1,
}

Role :: enum u16 {
	Responder  = 1,
	Authorizer = 2,
	Filter     = 3,
}

End_Request_Body :: struct #packed {
	app_status_b3:   u8,
	app_status_b2:   u8,
	app_status_b1:   u8,
	app_status_b0:   u8,
	protocol_status: Protocol_Status,
	reserved:        [3]u8,
}

Raw_Body :: distinct [dynamic]u8

Protocol_Status :: enum u8 {
	Request_Complete = 0,
	Cant_Mpx_Conn    = 1,
	Overloaded       = 2,
	Unknown_Role     = 3,
}

// Variable names for FCGI_GET_VALUES / FCGI_GET_VALUES_RESULT records
FCGI_MAX_CONNS :: "FCGI_MAX_CONNS"
FCGI_MAX_REQS :: "FCGI_MAX_REQS"
FCGI_MPXS_CONNS :: "FCGI_MPXS_CONNS"

ALLOWED_FCGI_GET_VALUES :: [?]string{FCGI_MAX_CONNS, FCGI_MAX_REQS, FCGI_MPXS_CONNS}

Unknown_Type_Body :: struct #packed {
	type:     Record_Type,
	reserved: [7]u8,
}

Http_Header :: struct {
	key, value: string,
}

Http_Status :: enum int {
	None                            = 0,
	Continue                        = 100,
	Switching_Protocols             = 101,
	Processing                      = 102,
	Early_hints                     = 103,
	Ok                              = 200,
	Created                         = 201,
	Accepted                        = 202,
	Non_Authoritative_Information   = 203,
	No_Content                      = 204,
	Reset_Content                   = 205,
	Partial_Content                 = 206,
	Multi_Status                    = 207,
	Already_Reported                = 208,
	IM_Used                         = 226,
	Multiple_Choices                = 300,
	Moved_Permanently               = 301,
	Found                           = 302,
	See_Other                       = 303,
	Not_Modified                    = 304,
	// Deprecated:
	// Use_Proxy = 305,
	// Unused = 306,
	Temporary_Redirect              = 307,
	Permanent_Redirect              = 308,
	Bad_Request                     = 400,
	Unauthorized                    = 401,
	Payment_Required                = 402,
	Forbidden                       = 403,
	Not_Found                       = 404,
	Method_Not_Allowed              = 405,
	Not_Acceptable                  = 406,
	Proxy_Authentication_Required   = 407,
	Request_Timeout                 = 408,
	Conflict                        = 409,
	Gone                            = 410,
	Length_Required                 = 411,
	Precondition_Failed             = 412,
	Content_Too_Large               = 413,
	URI_Too_Long                    = 414,
	Unsupported_Media_Type          = 415,
	Range_Not_Satisfiable           = 416,
	Expectation_Failed              = 417,
	Im_A_Teapot                     = 418,
	Misdirected_Request             = 421,
	Unprocessable_Entity            = 422,
	Locked                          = 423,
	Failed_Dependency               = 424,
	Too_Early                       = 425,
	Upgrade_Required                = 426,
	Precondition_Required           = 428,
	Too_Many_Requests               = 429,
	Request_Header_Fields_Too_Large = 431,
	Unavailable_For_Legal_Reasons   = 451,
	Internal_Server_Error           = 500,
	Not_Implemented                 = 501,
	Bad_Gateway                     = 502,
	Service_Unavailable             = 503,
	Gateway_Timeout                 = 504,
	Http_Version_Not_Supported      = 505,
	Variant_Also_Negotiates         = 506,
	Insufficient_Storage            = 507,
	Loop_Detected                   = 508,
	Not_Extended                    = 510,
	Network_Authentication_Required = 511,
}

Response :: struct {
	status:  Http_Status,
	headers: [dynamic]Http_Header,
	body:    [dynamic]u8,
}

On_Request :: proc(req: ^Request) -> (res: Response)
