//go:build windows

package cloud

import (
	"errors"
	"os"
)

func openTokenFile(_ string) (*os.File, error) {
	return nil, errors.New("secure token cache reads are unsupported on windows")
}
