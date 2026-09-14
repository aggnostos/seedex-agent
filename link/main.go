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
	"strings"
	"time"
)

var version = "dev"

type server struct {
	dir string
	sdx string
}

func main() {
	listen := flag.String("listen", ":8447", "address to listen on")
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

	srv := &http.Server{
		Addr:              *listen,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
		WriteTimeout:      60 * time.Second,
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
		if !strings.Contains(string(out), "no clients") {
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
