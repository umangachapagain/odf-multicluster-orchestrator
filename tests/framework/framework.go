package framework

import (
	"fmt"
	"os"
	"sync"

	replicationv1alpha1 "github.com/csi-addons/kubernetes-csi-addons/apis/replication.storage/v1alpha1"
	obv1alpha1 "github.com/kube-object-storage/lib-bucket-provisioner/pkg/apis/objectbucket.io/v1alpha1"
	snapshotv1 "github.com/kubernetes-csi/external-snapshotter/client/v8/apis/volumesnapshot/v1"
	. "github.com/onsi/ginkgo"
	. "github.com/onsi/gomega"
	consolev1 "github.com/openshift/api/console/v1"
	routev1 "github.com/openshift/api/route/v1"
	ramenv1alpha1 "github.com/ramendr/ramen/api/v1alpha1"
	ocsv1 "github.com/red-hat-storage/ocs-operator/api/v4/v1"
	multiclusterv1alpha1 "github.com/red-hat-storage/odf-multicluster-orchestrator/api/v1alpha1"
	rookv1 "github.com/rook/rook/pkg/apis/ceph.rook.io/v1"
	viewv1beta1 "github.com/stolostron/multicloud-operators-foundation/pkg/apis/view/v1beta1"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	extv1 "k8s.io/apiextensions-apiserver/pkg/apis/apiextensions/v1"
	"k8s.io/apimachinery/pkg/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
	clientcmdapi "k8s.io/client-go/tools/clientcmd/api"
	addonapiv1alpha1 "open-cluster-management.io/api/addon/v1alpha1"
	clusterv1 "open-cluster-management.io/api/cluster/v1"
	workv1 "open-cluster-management.io/api/work/v1"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/envtest"
)

var clusters sync.Map

type Cluster struct {
	Name        string
	Environment *envtest.Environment
	Scheme      *runtime.Scheme
	Config      *rest.Config
	K8sClient   client.Client
}

func NewCluster(name string) *Cluster {
	_, ok := clusters.Load(name)
	Expect(ok).To(BeFalseBecause("Another cluster already exists with given name %q.", name))

	env := &envtest.Environment{}

	scheme := runtime.NewScheme()
	var err error
	err = multiclusterv1alpha1.AddToScheme(scheme)
	Expect(err).NotTo(HaveOccurred())
	err = addonapiv1alpha1.AddToScheme(scheme)
	Expect(err).NotTo(HaveOccurred())
	err = clusterv1.AddToScheme(scheme)
	Expect(err).NotTo(HaveOccurred())
	err = ramenv1alpha1.AddToScheme(scheme)
	Expect(err).NotTo(HaveOccurred())
	err = clientgoscheme.AddToScheme(scheme)
	Expect(err).NotTo(HaveOccurred())
	err = consolev1.AddToScheme(scheme)
	Expect(err).NotTo(HaveOccurred())
	err = workv1.AddToScheme(scheme)
	Expect(err).NotTo(HaveOccurred())
	err = viewv1beta1.AddToScheme(scheme)
	Expect(err).NotTo(HaveOccurred())
	err = appsv1.AddToScheme(scheme)
	Expect(err).NotTo(HaveOccurred())
	err = replicationv1alpha1.AddToScheme(scheme)
	Expect(err).NotTo(HaveOccurred())
	err = corev1.AddToScheme(scheme)
	Expect(err).NotTo(HaveOccurred())
	err = ocsv1.AddToScheme(scheme)
	Expect(err).NotTo(HaveOccurred())
	err = obv1alpha1.AddToScheme(scheme)
	Expect(err).NotTo(HaveOccurred())
	err = routev1.AddToScheme(scheme)
	Expect(err).NotTo(HaveOccurred())
	err = rookv1.AddToScheme(scheme)
	Expect(err).NotTo(HaveOccurred())
	err = extv1.AddToScheme(scheme)
	Expect(err).NotTo(HaveOccurred())
	err = snapshotv1.AddToScheme(scheme)
	Expect(err).NotTo(HaveOccurred())

	cluster := &Cluster{
		Name:        name,
		Environment: env,
		Scheme:      scheme,
	}
	clusters.Store(name, cluster)
	return cluster
}

func (c *Cluster) WithCRD(paths []string) *Cluster {
	c.Environment.CRDInstallOptions = envtest.CRDInstallOptions{
		Paths:              paths,
		ErrorIfPathMissing: true,
	}
	return c
}

func (c *Cluster) WithScheme() *Cluster {
	return c
}

func (c *Cluster) Start() {
	cfg, err := c.Environment.Start()
	Expect(err).NotTo(HaveOccurred())
	Expect(cfg).NotTo(BeNil())

	k8sClient, err := client.New(cfg, client.Options{Scheme: c.Scheme})
	Expect(err).NotTo(HaveOccurred())
	Expect(k8sClient).NotTo(BeNil())

	c.Config = cfg
	c.K8sClient = k8sClient
}

func GetCluster(name string) *Cluster {
	c, ok := clusters.Load(name)
	Expect(ok).To(BeTrue())
	cluster, ok := c.(*Cluster)
	Expect(ok).To(BeTrue())
	return cluster
}

func StopAllClusters() {
	clusters.Range(func(key, value any) bool {
		fmt.Fprintf(GinkgoWriter, "Stopping cluster %q.", key)
		cluster, ok := value.(*Cluster)
		if !ok {
			return false
		}
		return cluster.Environment.Stop() == nil
	})
}

func CreateKubeconfigFileForRestConfig(restConfig rest.Config) string {
	clusters := make(map[string]*clientcmdapi.Cluster)
	clusters["default-cluster"] = &clientcmdapi.Cluster{
		Server:                   restConfig.Host,
		CertificateAuthorityData: restConfig.CAData,
	}
	contexts := make(map[string]*clientcmdapi.Context)
	contexts["default-context"] = &clientcmdapi.Context{
		Cluster:  "default-cluster",
		AuthInfo: "default-user",
	}
	authinfos := make(map[string]*clientcmdapi.AuthInfo)
	authinfos["default-user"] = &clientcmdapi.AuthInfo{
		ClientCertificateData: restConfig.CertData,
		ClientKeyData:         restConfig.KeyData,
	}
	clientConfig := clientcmdapi.Config{
		Kind:           "Config",
		APIVersion:     "v1",
		Clusters:       clusters,
		Contexts:       contexts,
		CurrentContext: "default-context",
		AuthInfos:      authinfos,
	}
	kubeConfigFile, err := os.CreateTemp("", "kubeconfig")
	Expect(err).To(BeNil())
	err = clientcmd.WriteToFile(clientConfig, kubeConfigFile.Name())
	Expect(err).To(BeNil())
	return kubeConfigFile.Name()
}
