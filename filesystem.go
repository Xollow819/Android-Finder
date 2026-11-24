package main

import (
	"context"
	"fmt"
	"io"
	"mime"
	"os"
	"path"
	"slices"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"

	"golang.org/x/net/webdav"
)

type androidStorage interface {
	list(context.Context, mtpObject) ([]mtpObject, error)
	readAt(context.Context, mtpObject, []byte, int64) (int, error)
	download(context.Context, mtpObject, *os.File) error
}

type folderCache struct {
	until time.Time
	items []mtpObject
}

type androidFS struct {
	storage androidStorage
	tempDir string
	mu      sync.Mutex
	folders map[[2]uint32]folderCache
}

func (fs *androidFS) children(ctx context.Context, folder mtpObject) ([]mtpObject, error) {
	fs.mu.Lock()
	defer fs.mu.Unlock()
	key := [2]uint32{folder.storage, folder.id}
	if cached, ok := fs.folders[key]; ok && time.Now().Before(cached.until) {
		return cached.items, nil
	}
	items, err := fs.storage.list(ctx, folder)
	if err != nil {
		return nil, err
	}
	taken := make(map[string]bool, len(items))
	slices.SortFunc(items, func(a, b mtpObject) int {
		if folder.storage == 0 {
			if a.storage < b.storage {
				return -1
			}
			if a.storage > b.storage {
				return 1
			}
			return 0
		}
		if a.id < b.id {
			return -1
		}
		if a.id > b.id {
			return 1
		}
		return 0
	})
	for i := range items {
		item := &items[i]
		name := strings.Map(func(r rune) rune {
			if unicode.IsControl(r) || r == '/' || r == ':' || r == '\uFFFE' || r == '\uFFFF' {
				return '_'
			}
			return r
		}, strings.ToValidUTF8(item.name, "_"))
		if name == "" || name == "." || name == ".." {
			name = "Unnamed"
		}
		removeTail := func(s string, limit int) string {
			for len(s) > limit {
				_, size := utf8.DecodeLastRuneInString(s)
				s = s[:len(s)-size]
			}
			return s
		}
		name = removeTail(name, 240)
		candidate := name
		if taken[strings.ToLower(candidate)] {
			for suffix := 2; ; suffix++ {
				extension := path.Ext(name)
				if len(extension) > 30 {
					extension = ""
				}
				candidate = fmt.Sprintf("%s (%d)%s",
					removeTail(strings.TrimSuffix(name, extension), 225-len(extension)), suffix, extension)
				if !taken[strings.ToLower(candidate)] {
					break
				}
			}
		}
		item.name = candidate
		taken[strings.ToLower(candidate)] = true
	}
	if len(fs.folders) >= 256 {
		clear(fs.folders)
	}
	fs.folders[key] = folderCache{time.Now().Add(3 * time.Second), items}
	return items, nil
}

func (fs *androidFS) resolve(ctx context.Context, name string) (mtpObject, error) {
	object := mtpObject{name: "Android", directory: true}
	clean := path.Clean("/" + name)
	if clean == "/" {
		return object, nil
	}
	for _, component := range strings.Split(strings.TrimPrefix(clean, "/"), "/") {
		if !object.directory {
			return mtpObject{}, os.ErrNotExist
		}
		items, err := fs.children(ctx, object)
		if err != nil {
			return mtpObject{}, err
		}
		index := slices.IndexFunc(items, func(item mtpObject) bool {
			return item.name == component
		})
		if index < 0 {
			return mtpObject{}, os.ErrNotExist
		}
		object = items[index]
	}
	return object, nil
}

func (fs *androidFS) Stat(ctx context.Context, name string) (os.FileInfo, error) {
	object, err := fs.resolve(ctx, name)
	return objectInfo{object}, err
}

func (fs *androidFS) OpenFile(ctx context.Context, name string, flags int, _ os.FileMode) (webdav.File, error) {
	if flags != os.O_RDONLY {
		return nil, os.ErrPermission
	}
	object, err := fs.resolve(ctx, name)
	if err != nil {
		return nil, err
	}
	return &androidFile{fs: fs, object: object, ctx: ctx}, nil
}

func (*androidFS) Mkdir(context.Context, string, os.FileMode) error { return os.ErrPermission }
func (*androidFS) RemoveAll(context.Context, string) error          { return os.ErrPermission }
func (*androidFS) Rename(context.Context, string, string) error     { return os.ErrPermission }

type objectInfo struct{ mtpObject }

func (o objectInfo) Name() string       { return o.name }
func (o objectInfo) Size() int64        { return o.size }
func (o objectInfo) IsDir() bool        { return o.directory }
func (o objectInfo) ModTime() time.Time { return o.modified }
func (o objectInfo) Sys() any           { return nil }
func (o objectInfo) Mode() os.FileMode {
	if o.directory {
		return os.ModeDir | 0555
	}
	return 0444
}

func (o objectInfo) ContentType(context.Context) (string, error) {
	if value := mime.TypeByExtension(path.Ext(o.name)); value != "" {
		return value, nil
	}
	return "application/octet-stream", nil
}

type androidFile struct {
	fs        *androidFS
	object    mtpObject
	ctx       context.Context
	offset    int64
	dirOffset int
	temp      *os.File
}

func (file *androidFile) Stat() (os.FileInfo, error) { return objectInfo{file.object}, nil }
func (*androidFile) Write([]byte) (int, error)       { return 0, os.ErrPermission }

func (file *androidFile) Close() error {
	if file.temp == nil {
		return nil
	}
	return file.temp.Close()
}

func (file *androidFile) Seek(offset int64, whence int) (int64, error) {
	switch whence {
	case io.SeekStart:
	case io.SeekCurrent:
		offset += file.offset
	case io.SeekEnd:
		offset += file.object.size
	default:
		return 0, os.ErrInvalid
	}
	if offset < 0 || file.object.directory {
		return 0, os.ErrInvalid
	}
	file.offset = offset
	return offset, nil
}

func (file *androidFile) Read(buffer []byte) (int, error) {
	if file.object.directory {
		return 0, os.ErrInvalid
	}
	if len(buffer) == 0 {
		return 0, nil
	}
	if file.offset >= file.object.size {
		return 0, io.EOF
	}
	buffer = buffer[:min(int64(len(buffer)), file.object.size-file.offset)]

	if file.temp == nil {
		count, err := file.fs.storage.readAt(file.ctx, file.object, buffer, file.offset)
		if err != errPartialUnavailable {
			file.offset += int64(count)
			return count, err
		}
		temp, err := os.CreateTemp(file.fs.tempDir, "transfer-*")
		if err != nil {
			return 0, err
		}
		if err := os.Remove(temp.Name()); err != nil {
			temp.Close()
			return 0, err
		}
		if err := file.fs.storage.download(file.ctx, file.object, temp); err != nil {
			temp.Close()
			return 0, err
		}
		file.temp = temp
	}
	count, err := file.temp.ReadAt(buffer, file.offset)
	file.offset += int64(count)
	return count, err
}

func (file *androidFile) Readdir(count int) ([]os.FileInfo, error) {
	if !file.object.directory {
		return nil, os.ErrInvalid
	}
	items, err := file.fs.children(file.ctx, file.object)
	if err != nil {
		return nil, err
	}
	end := len(items)
	start := min(file.dirOffset, end)
	if count > 0 {
		if start == end {
			return nil, io.EOF
		}
		end = start + min(count, end-start)
	}
	infos := make([]os.FileInfo, 0, end-start)
	for _, item := range items[start:end] {
		infos = append(infos, objectInfo{item})
	}
	file.dirOffset = end
	return infos, nil
}
