package main

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

var version = "dev"

type server struct {
	dir string
	sdx string
}

func main() {
	listen := flag.String("listen", ":8282", "address to listen on")
	dir := flag.String("dir", "/etc/seedex/link", "directory with cert.pem, key.pem and routers/")
	sdx := flag.String("sdx", "/usr/local/bin/sdx", "sdx binary used to export configs")
	showVersion := flag.Bool("version", false, "print the version and exit")
	flag.Parse()

	if *showVersion {
		fmt.Println(version)
		return
	}

	s := &server{dir: *dir, sdx: *sdx}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/configs", s.configs)
	mux.HandleFunc("POST /v1/run", s.run)

	srv := &http.Server{
		Addr:              *listen,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
		WriteTimeout:      150 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	log.Printf("seedex-link %s listening on %s", version, *listen)
	log.Fatal(srv.ListenAndServeTLS(filepath.Join(*dir, "cert.pem"), filepath.Join(*dir, "key.pem")))
}

func (s *server) configs(w http.ResponseWriter, r *http.Request) {
	router, err := s.authenticate(r)
	if err != nil {
		log.Printf("%s: %v", r.RemoteAddr, err)
		w.Header().Set("WWW-Authenticate", "Bearer")
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	out, err := s.export(router)
	if err != nil {
		log.Printf("%s: export for %s failed: %v", r.RemoteAddr, router, err)
		http.Error(w, "export failed", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	if err := json.NewEncoder(w).Encode(out); err != nil {
		log.Printf("%s: write failed: %v", r.RemoteAddr, err)
	}
	log.Printf("%s: configs for %s", r.RemoteAddr, router)
}

func (s *server) authenticate(r *http.Request) (string, error) {
	token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok || token == "" {
		return "", errors.New("no bearer token")
	}
	sum := sha256.Sum256([]byte(token))
	want := []byte(hex.EncodeToString(sum[:]))

	entries, err := os.ReadDir(filepath.Join(s.dir, "routers"))
	if err != nil {
		return "", fmt.Errorf("no routers directory: %w", err)
	}
	for _, e := range entries {
		name, ok := strings.CutSuffix(e.Name(), ".token")
		if !ok || e.IsDir() {
			continue
		}
		stored, err := os.ReadFile(filepath.Join(s.dir, "routers", e.Name()))
		if err != nil {
			continue
		}
		if subtle.ConstantTimeCompare([]byte(strings.TrimSpace(string(stored))), want) == 1 {
			return name, nil
		}
	}
	return "", errors.New("unknown token")
}

type payload struct {
	VPN   map[string]string          `json:"vpn"`
	Proxy map[string]json.RawMessage `json:"proxy"`
}

func (s *server) export(router string) (*payload, error) {
	tmp, err := os.MkdirTemp("", "seedex-link")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(tmp)

	vpnDir := filepath.Join(tmp, "vpn")
	proxyDir := filepath.Join(tmp, "proxy")
	if out, err := exec.Command(s.sdx, "vpn", "export", "-o", vpnDir).CombinedOutput(); err != nil {
		if !strings.Contains(string(out), "no clients") && !strings.Contains(string(out), "no protocols configured") {
			return nil, fmt.Errorf("vpn export: %s", strings.TrimSpace(string(out)))
		}
	}
	if out, err := exec.Command(s.sdx, "proxy", "export", "-o", proxyDir).CombinedOutput(); err != nil {
		if !strings.Contains(string(out), "no protocols configured") {
			return nil, fmt.Errorf("proxy export: %s", strings.TrimSpace(string(out)))
		}
	}

	p := &payload{VPN: map[string]string{}, Proxy: map[string]json.RawMessage{}}
	files, _ := filepath.Glob(filepath.Join(vpnDir, "*.conf"))
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			return nil, err
		}
		p.VPN[filepath.Base(f)] = string(b)
	}
	files, _ = filepath.Glob(filepath.Join(proxyDir, "*.json"))
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			return nil, err
		}
		if !json.Valid(b) {
			return nil, fmt.Errorf("%s is not valid JSON", filepath.Base(f))
		}
		p.Proxy[filepath.Base(f)] = json.RawMessage(b)
	}
	return p, nil
}

var argPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:=+-]{0,63}$`)

var actions = map[string]bool{
	"start": true, "stop": true, "restart": true, "config": true,
	"rotate": true, "add": true, "remove": true, "help": true,
}

var mutating = map[string]bool{"add": true, "remove": true, "rotate": true}

func validate(args []string) error {
	if len(args) > 8 {
		return errors.New("too many arguments")
	}
	for _, a := range args {
		if !argPattern.MatchString(a) {
			return fmt.Errorf("invalid argument %q", a)
		}
	}
	if len(args) == 0 {
		return nil
	}
	switch args[0] {
	case "vpn", "proxy":
		if len(args) == 1 {
			return nil
		}
		if !actions[args[1]] {
			return fmt.Errorf("%s %s is not allowed over the link", args[0], args[1])
		}
	case "start", "stop", "restart", "help", "version":
		if len(args) > 1 {
			return fmt.Errorf("%s takes no arguments", args[0])
		}
	default:
		return fmt.Errorf("%s is not allowed over the link", args[0])
	}
	return nil
}

func (s *server) exportHash(router string) string {
	p, err := s.export(router)
	if err != nil {
		return ""
	}
	b, _ := json.Marshal(p)
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

type runResult struct {
	Code    int    `json:"code"`
	Output  string `json:"output"`
	Error   string `json:"error"`
	Changed bool   `json:"changed"`
}

func (s *server) run(w http.ResponseWriter, r *http.Request) {
	router, err := s.authenticate(r)
	if err != nil {
		log.Printf("%s: %v", r.RemoteAddr, err)
		w.Header().Set("WWW-Authenticate", "Bearer")
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	var req struct {
		Args []string `json:"args"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	if err := validate(req.Args); err != nil {
		log.Printf("%s: %s rejected: %v", r.RemoteAddr, router, err)
		http.Error(w, err.Error(), http.StatusForbidden)
		return
	}

	mutates := len(req.Args) > 1 && mutating[req.Args[1]]
	before := ""
	if mutates {
		before = s.exportHash(router)
	}

	cmd := exec.Command(s.sdx, req.Args...)
	var stdout, stderr strings.Builder
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	cmd.WaitDelay = 5 * time.Second
	res := runResult{}
	done := make(chan error, 1)
	go func() { done <- cmd.Run() }()
	select {
	case err := <-done:
		var exit *exec.ExitError
		if errors.As(err, &exit) {
			res.Code = exit.ExitCode()
		} else if err != nil {
			res.Code = 1
			stderr.WriteString(err.Error())
		}
	case <-time.After(120 * time.Second):
		_ = cmd.Process.Kill()
		<-done
		res.Code = 1
		stderr.WriteString("timed out")
	}
	res.Output = strings.TrimRight(stdout.String(), "\n")
	res.Error = strings.TrimRight(stderr.String(), "\n")
	if mutates {
		res.Changed = s.exportHash(router) != before
	}

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	if err := json.NewEncoder(w).Encode(res); err != nil {
		log.Printf("%s: write failed: %v", r.RemoteAddr, err)
	}
	log.Printf("%s: %s ran sdx %s (exit %d)", r.RemoteAddr, router, strings.Join(req.Args, " "), res.Code)
}
