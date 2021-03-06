########################################################################
#
#  0 setup environment, install libraries if necessary, load libraries
# 
# ######################################################################

library(Seurat)
library(dplyr)
library(cowplot)
library(kableExtra)
library(magrittr)
library(harmony)
library(scran)
source("R/utils/Seurat3_functions.R")
path <- paste0("output/",gsub("-","",Sys.Date()),"/")
if(!dir.exists(path))dir.create(path, recursive = T)
########################################################################
#
#  1 Seurat setup
# 
# ######################################################################
#======1.1 Setup the Seurat objects =========================
# Load the mouse.eyes dataset

# setup Seurat objects since both count matrices have already filtered
# cells, we do no additional filtering here
df_samples <- readxl::read_excel("doc/sample_list.xls")
colnames(df_samples) <- colnames(df_samples) %>% tolower
(samples = df_samples$sample)

#======1.2 load  SingleCellExperiment =========================
(load(file = "data/sce_mm10_2_20190710.Rda"))
names(sce_list)
object_list <- lapply(sce_list, as.Seurat)

for(i in 1:length(samples)){
    object_list[[i]]$orig.ident <- df_samples$sample[i]
    object_list[[i]]$conditions <- df_samples$conditions[i]
    }

#========1.3 merge ===================================
object <- Reduce(function(x, y) merge(x, y, do.normalize = F), object_list)
object@assays$RNA@data = object@assays$RNA@data *log(2) # change to natural log
remove(sce_list,object_list);GC()
save(object, file = paste0("data/mm10_young_aged_eyes_",length(df_samples$sample),"_",gsub("-","",Sys.Date()),".Rda"))

#======1.2 QC, pre-processing and normalizing the data=========================
# store mitochondrial percentage in object meta data
object <- PercentageFeatureSet(object = object, pattern = "^mt-", col.name = "percent.mt")
Idents(object) = "orig.ident"
Idents(object) %<>% factor(levels = samples)
(load(file = paste0(path, "g1_2_20190710.Rda")))

object %<>% subset(subset = nFeature_RNA > 800 & nCount_RNA > 1900 & percent.mt < 10)
# FilterCellsgenerate Vlnplot before and after filteration
g2 <- lapply(c("nFeature_RNA", "nCount_RNA", "percent.mt"), function(features){
    VlnPlot(object = object, features = features, ncol = 3, pt.size = 0.01)+
        theme(axis.text.x = element_text(size=15),legend.position="none")
})

save(g2,file= paste0(path,"g2_2_20190710.Rda"))
jpeg(paste0(path,"S1_nGene.jpeg"), units="in", width=10, height=7,res=600)
print(plot_grid(g1[[1]]+ggtitle("nFeature_RNA before filteration")+
                    scale_y_log10(limits = c(100,10000)),
                g2[[1]]+ggtitle("nFeature_RNA after filteration")+
                    scale_y_log10(limits = c(100,10000))))
dev.off()
jpeg(paste0(path,"S1_nUMI.jpeg"), units="in", width=10, height=7,res=600)
print(plot_grid(g1[[2]]+ggtitle("nCount_RNA before filteration")+
                    scale_y_log10(limits = c(500,100000)),
                g2[[2]]+ggtitle("nCount_RNA after filteration")+ 
                    scale_y_log10(limits = c(500,100000))))
dev.off()
jpeg(paste0(path,"S1_mito.jpeg"), units="in", width=10, height=7,res=600)
print(plot_grid(g1[[3]]+ggtitle("mito % before filteration")+
                    ylim(c(0,50)),
                g2[[3]]+ggtitle("mito % after filteration")+ 
                    ylim(c(0,50))))
dev.off()

######################################
# After removing unwanted cells from the dataset, the next step is to normalize the data.
object <- FindVariableFeatures(object = object, selection.method = "vst",
                            num.bin = 20,
                            mean.cutoff = c(0.1, 8), dispersion.cutoff = c(1, Inf))

# Identify the 10 most highly variable genes
top20 <- head(VariableFeatures(object), 20)

# plot variable features with and without labels
plot1 <- VariableFeaturePlot(object)
plot2 <- LabelPoints(plot = plot1, points = top20, repel = TRUE)
jpeg(paste0(path,"VariableFeaturePlot.jpeg"), units="in", width=10, height=7,res=600)
print(plot2)
dev.off()
#======1.3 1st run of pca-tsne  =========================
DefaultAssay(object) <- "RNA"
object %<>% SCTransform
object %<>% RunPCA(verbose =F,npcs = 100)
object <- JackStraw(object, num.replicate = 20,dims = 100)
object <- ScoreJackStraw(object, dims = 1:100)
jpeg(paste0(path,"JackStrawPlot~.jpeg"), units="in", width=10, height=7,res=600)
JackStrawPlot(object, dims = 70:80)
dev.off()
npcs =75
object %<>% FindNeighbors(reduction = "pca",dims = 1:npcs)
object %<>% FindClusters(reduction = "pca",resolution = 0.6,
                       dims.use = 1:npcs,print.output = FALSE)
object %<>% RunTSNE(reduction = "pca", dims = 1:npcs)
object %<>% RunUMAP(reduction = "pca", dims = 1:npcs)

p0 <- TSNEPlot.1(object, group.by="orig.ident",pt.size = 1,label = F,
                 label.size = 4, repel = T,title = "Original tsne plot")
p1 <- UMAPPlot(object, group.by="orig.ident",pt.size = 1,label = F,
               label.size = 4, repel = T)+ggtitle("Original umap plot")+
    theme(plot.title = element_text(hjust = 0.5,size=15,face = "plain"))

#======1.4 Performing CCA integration =========================
set.seed(100)
Idents(object) = "orig.ident"
object_list <- lapply(df_samples$sample,function(x) subset(object,idents=x))
anchors <- FindIntegrationAnchors(object.list = object_list, dims = 1:npcs)
object <- IntegrateData(anchorset = anchors, dims = 1:npcs)
remove(anchors,object_list);GC()
DefaultAssay(object) <- "integrated"
object %<>% ScaleData(verbose = FALSE)
object %<>% RunPCA(npcs = npcs, features = VariableFeatures(object),verbose = FALSE)
object %<>% FindNeighbors(reduction = "pca",dims = 1:npcs)
object %<>% FindClusters(reduction = "pca",resolution = 0.6,
                         dims.use = 1:npcs,print.output = FALSE)
object %<>% RunTSNE(reduction = "pca", dims = 1:npcs)
object %<>% RunUMAP(reduction = "pca", dims = 1:npcs)

p2 <- TSNEPlot.1(object, group.by="orig.ident",pt.size = 1,label = F,
                 label.size = 4, repel = T,title = "CCA tsne plot")
p3 <- UMAPPlot(object, group.by="orig.ident",pt.size = 1,label = F,
               label.size = 4, repel = T)+ggtitle("CCA umap plot")+
    theme(plot.title = element_text(hjust = 0.5,size=15,face = "plain"))

jpeg(paste0(path,"S1_cca_TSNEPlot.jpeg"), units="in", width=10, height=7,res=600)
plot_grid(p0+ theme(legend.position="bottom"),p2+ theme(legend.position="bottom"))
dev.off()

jpeg(paste0(path,"S1_cca_UMAP.jpeg"), units="in", width=10, height=7,res=600)
plot_grid(p1+ theme(legend.position="bottom"),p3+ theme(legend.position="bottom"))
dev.off()

Idents(object) = "integrated_snn_res.0.6"
TSNEPlot.1(object, group.by="integrated_snn_res.0.6",pt.size = 1,label = F,
           label.size = 4, repel = T,title = "All cluster in tSNE plot",do.print = T)

UMAPPlot.1(object, group.by="integrated_snn_res.0.6",pt.size = 1,label = F,
               label.size = 4, repel = T,title = "All cluster in UMAP plot",do.print = T)

object@assays$integrated@scale.data = matrix(0,0,0)
save(object,file = paste0("data/mm10_young_aged_eyes_",length(df_samples$sample),"_",gsub("-","",Sys.Date()),".Rda"))
