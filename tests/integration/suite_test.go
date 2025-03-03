//go:build integration
// +build integration

/*
Copyright 2021 Red Hat OpenShift Data Foundation.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package integration_test

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"testing"

	. "github.com/onsi/ginkgo"
	. "github.com/onsi/gomega"
	"github.com/red-hat-storage/odf-multicluster-orchestrator/cmd"
	"github.com/red-hat-storage/odf-multicluster-orchestrator/tests/framework"
	//+kubebuilder:scaffold:imports
)

var ctx, cancel = context.WithCancel(context.Background())

func TestMulticlusterOrchestrator(t *testing.T) {
	RegisterFailHandler(Fail)

	RunSpecs(t, "Controller Suite")
}

var _ = BeforeSuite(func() {
	slog.Info("Preparing test environment")

	slog.Info("Starting hub cluster", "name", "hub")
	framework.NewCluster("hub").WithCRD([]string{
		filepath.Join("../..", "config", "crd", "bases"),
		filepath.Join("..", "testdata"),
	}).Start()

	hubKubeconfig := framework.CreateKubeconfigFileForRestConfig(*framework.GetCluster("hub").Config)
	slog.Info(fmt.Sprintf("Hub kubeconfig path=%s", hubKubeconfig))

	namespace := framework.GetNamespace("openshift-operators")
	Expect(framework.GetCluster("hub").K8sClient.Create(ctx, &namespace)).To(BeNil())

	cluster1Namespace := framework.GetNamespace("cluster1")
	Expect(framework.GetCluster("hub").K8sClient.Create(ctx, &cluster1Namespace)).To(BeNil())
	slog.Info("Namespace created")

	consoleDeployment := framework.GetDeployment("odf-multicluster-console", "openshift-operators")
	Expect(framework.GetCluster("hub").K8sClient.Create(ctx, &consoleDeployment)).To(BeNil())
	slog.Info("Deployment created")

	go func(ctx context.Context) {
		defer GinkgoRecover()
		os.Setenv("POD_NAMESPACE", "openshift-operators")
		os.Setenv("TOKEN_EXCHANGE_IMAGE", "busybox")
		_, _ = cmd.ExecuteCommandForTest(ctx, []string{
			"manager", "--dev", "true",
			"--kubeconfig", hubKubeconfig,
		})
		<-ctx.Done()
		slog.Info("**MCO HUB CONTROLLERS STOPPED**")
	}(ctx)

	slog.Info("Starting spoke cluster", "name", "cluster1")
	framework.NewCluster("cluster1").WithCRD([]string{
		filepath.Join("../..", "config", "crd", "bases"),
		filepath.Join("..", "testdata"),
	}).Start()

	cluster1Kubeconfig := framework.CreateKubeconfigFileForRestConfig(*framework.GetCluster("cluster1").Config)
	slog.Info(fmt.Sprintf("Cluster1 kubeconfig path=%s", cluster1Kubeconfig))

	storageNamespace := framework.GetNamespace("openshift-storage")
	Expect(framework.GetCluster("cluster1").K8sClient.Create(ctx, &storageNamespace)).To(BeNil())
	slog.Info("Namespace created")

	go func(ctx context.Context) {
		defer GinkgoRecover()
		os.Setenv("POD_NAMESPACE", "openshift-storage")
		_, _ = cmd.ExecuteCommandForTest(ctx, []string{
			"addons", "--dev", "true",
			"--hub-kubeconfig", hubKubeconfig,
			"--kubeconfig", cluster1Kubeconfig,
			"--cluster-name", "cluster1",
			"--odf-operator-namespace", "openshift-storage",
			"--mode", "async"})
		<-ctx.Done()
		slog.Info("**CLUSTER1 CONTROLLERS STOPPED**")
	}(ctx)

})

var _ = AfterSuite(func() {
	slog.Info("Destroying test environment")
	cancel()
	<-ctx.Done()
	framework.StopAllClusters()
})
