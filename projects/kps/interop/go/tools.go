//go:build tools

// The reference Go client and server, pinned by commit in go.mod, built by `wac task deps` into interop/go/bin.
// Nothing here is wac-kps's own code: these are the implementations it is judged against.
package interop

import (
	_ "github.com/ethereum/kps/libs/go/cmd/dial"
	_ "github.com/ethereum/kps/libs/go/cmd/server"
)
