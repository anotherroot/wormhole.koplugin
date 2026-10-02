// wormhole-helper: the network side of the KOReader Wormhole plugin.
// It prints one JSON event per line on stdout (see events.go) and is
// stopped with SIGTERM to cancel.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	"github.com/psanford/wormhole-william/wormhole"
)

const usage = `usage:
  wormhole-helper send-text  --control DIR [opts] --text-file F
  wormhole-helper send-file  --control DIR [opts] PATH
  wormhole-helper send-files --control DIR [opts] --name NAME PATH...
  wormhole-helper receive    --control DIR [opts] --code CODE --dir DIR
opts: --rendezvous URL --relay HOST:PORT --tmp DIR`

func main() {
	os.Exit(run(os.Args[1:], NewEmitter(os.Stdout)))
}

func run(args []string, em *Emitter) int {
	if len(args) < 1 {
		fmt.Fprintln(os.Stderr, usage)
		return 2
	}
	cmd := args[0]
	fl := flag.NewFlagSet(cmd, flag.ContinueOnError)
	control := fl.String("control", "", "working folder of this transfer")
	rendezvous := fl.String("rendezvous", "", "rendezvous server URL")
	relay := fl.String("relay", "", "transit relay host:port")
	textFile := fl.String("text-file", "", "file holding the text to send")
	name := fl.String("name", "", "folder name for send-files")
	code := fl.String("code", "", "code to receive")
	dir := fl.String("dir", "", "folder to save received files in")
	tmp := fl.String("tmp", "", "folder for temporary files (default: $TMPDIR or /tmp)")
	if err := fl.Parse(args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, usage)
		return 2
	}

	if *tmp != "" {
		if err := useTmpDir(*tmp); err != nil {
			em.Error(err)
			return 1
		}
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	c := &wormhole.Client{RendezvousURL: *rendezvous, TransitRelayAddress: *relay}

	var err error
	switch {
	case cmd == "send-text" && *textFile != "":
		var b []byte
		if b, err = os.ReadFile(*textFile); err == nil {
			err = SendText(ctx, c, em, string(b))
		}
	case cmd == "send-file" && fl.NArg() == 1:
		err = SendFile(ctx, c, em, fl.Arg(0))
	case cmd == "send-files" && *name != "" && fl.NArg() >= 1:
		err = SendFiles(ctx, c, em, *name, fl.Args())
	case cmd == "receive" && *code != "" && *dir != "" && *control != "":
		err = Receive(ctx, c, em, *code, *dir, *control)
	default:
		fmt.Fprintln(os.Stderr, usage)
		return 2
	}
	if err == nil {
		return 0
	}
	if ctx.Err() != nil { // SIGTERM wins over whatever error the cancel caused
		err = context.Canceled
	}
	if !errors.Is(err, errAlreadyReported) {
		em.Error(err)
	}
	fmt.Fprintln(os.Stderr, err)
	return 1
}

// useTmpDir makes dir the temp folder (wormhole-william zips a folder there
// before sending it). On a Kobo /tmp is RAM, so the plugin passes a folder on
// the storage. Temp zips left by a helper that was killed are removed first.
func useTmpDir(dir string) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	stale, _ := filepath.Glob(filepath.Join(dir, "wormhole-william-dir*"))
	for _, p := range stale {
		os.Remove(p)
	}
	return os.Setenv("TMPDIR", dir)
}
