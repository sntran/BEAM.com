// A WASI preview 1 program in Go, for wasm_check:
//
//	GOOS=wasip1 GOARCH=wasm go build -o hello_go.wasm .
//	./wasm_check.com hello_go.wasm one two
//
// It uses the arguments, the environment and the file system (the
// directory that wasm_check gives as "/").
package main

import (
	"fmt"
	"os"
	"strings"
)

func main() {
	fmt.Printf("go: hello from wasip1, args %v\n", os.Args[1:])
	fmt.Printf("go: BEAM_COM=%s\n", os.Getenv("BEAM_COM"))
	if err := os.WriteFile("hello_go.txt", []byte("written by go\n"), 0o644); err != nil {
		fmt.Println("go: write failed:", err)
		os.Exit(1)
	}
	b, err := os.ReadFile("hello_go.txt")
	if err != nil {
		fmt.Println("go: read failed:", err)
		os.Exit(1)
	}
	os.Remove("hello_go.txt")
	fmt.Printf("go: read back %q\n", strings.TrimSpace(string(b)))
}
