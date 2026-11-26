// A separate module for the lab client. The replace line points to the agent module of this
// repository, so the client uses the proto package of the agent. The lab built it against commit
// bcc4376f. The module is not in go.work: build it with GOWORK=off.
module nvke-lab-client

go 1.27.4

require (
	github.com/dsx-ai-factory/nvke/agent v0.0.0
	github.com/spiffe/go-spiffe/v2 v2.9.0
	google.golang.org/grpc v1.85.0
)

require (
	github.com/Microsoft/go-winio v0.6.2 // indirect
	github.com/go-jose/go-jose/v4 v4.1.9 // indirect
	golang.org/x/net v0.62.0 // indirect
	golang.org/x/sys v0.50.0 // indirect
	golang.org/x/text v0.44.0 // indirect
	google.golang.org/genproto/googleapis/rpc v0.0.0-20261104224025-d1e00e9f33ab // indirect
	google.golang.org/protobuf v1.36.12 // indirect
)

replace github.com/dsx-ai-factory/nvke/agent => ../../../../../agent
