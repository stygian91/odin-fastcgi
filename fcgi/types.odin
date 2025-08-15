package fcgi

Record_Header :: struct #packed {
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

Begin_Request_Body :: struct #packed {
	role_b1:  u8,
	role_b0:  u8,
	flags:    bit_set[Begin_Request_Body_Flags;u8],
	reserved: [5]u8,
}

Begin_Request_Body_Flags :: enum u8 {
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

Unknown_Type_Body :: struct #packed {
	type:     Record_Type,
	reserved: [7]u8,
}
