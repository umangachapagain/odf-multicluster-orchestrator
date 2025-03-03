package integration_test

import (
	"time"

	. "github.com/onsi/ginkgo"
	. "github.com/onsi/gomega"
)

var _ = Describe("ODF/Internal Mode/Local Client/Regional DR", func() {
	It("Always True", func() {
		time.Sleep(15 * time.Second)
		Expect(1).To(BeEquivalentTo(1))
	})
})
