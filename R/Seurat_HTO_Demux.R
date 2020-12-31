#' @include Utils.R
#' @include Visualization.R

utils::globalVariables(
	names = c('p_val_adj', 'avg_logFC', 'cluster'),
	package = 'cellhashR',
	add = TRUE
)

GenerateCellHashCallsSeurat <- function(barcodeMatrix, positive.quantile = 0.95) {
	seuratObj <- CreateSeuratObject(barcodeMatrix, assay = 'HTO')

	tryCatch({
		seuratObj <- DoHtoDemux(seuratObj, positive.quantile = positive.quantile)

		return(data.frame(cellbarcode = as.factor(colnames(seuratObj)), method = 'htodemux', classification= seuratObj$classification.htodemux, classification.global = seuratObj$classification.global.htodemux, stringsAsFactors = FALSE))
	}, error = function(e){
		print('Error generating seurat htodemux calls, aborting')
		print(e)

		return(NULL)
	})
}


DoHtoDemux <- function(seuratObj, positive.quantile, label = 'Seurat HTODemux', plotDist = FALSE) {
	# Normalize HTO data, here we use centered log-ratio (CLR) transformation
	seuratObj <- NormalizeData(seuratObj, assay = "HTO", normalization.method = "CLR", verbose = FALSE)

	seuratObj <- HTODemux(seuratObj, positive.quantile =  positive.quantile, plotDist = plotDist)
	seuratObj$classification.htodemux <- naturalsort::naturalfactor(as.character(seuratObj$classification.htodemux))
	seuratObj$classification.global.htodemux <- naturalsort::naturalfactor(as.character(seuratObj$classification.global.htodemux))

	SummarizeHashingCalls(seuratObj, label = label, htoClassificationField = 'classification.htodemux', globalClassificationField = 'classification.global.htodemux')

	return(seuratObj)
}


#' @import Seurat
#' @importFrom fitdistrplus fitdist
#' @importFrom cluster clara
#' @importFrom Matrix t
#' @author Seurat
#' url https://www.rdocumentation.org/packages/Seurat/versions/3.1.4/topics/HTODemux
HTODemux <- function(
	object,
	assay = "HTO",
	positive.quantile = 0.98,
	nstarts = 100,
	kfunc = "clara",
	nsamples = 100,
	verbose = TRUE,
	plotDist = FALSE
) {
	if (verbose) {
		print('Starting HTODemux')
	}

	#initial clustering
	data <- GetAssayData(object = object, assay = assay)
	counts <- GetAssayData(
		object = object,
		assay = assay,
		slot = 'counts'
	)[, colnames(x = object)]

	ncenters <- (nrow(x = data) + 1)
	switch(
		EXPR = kfunc,
		'kmeans' = {
			init.clusters <- stats::kmeans(
				x = t(x = data),
				centers = ncenters,
				nstart = nstarts
			)
			#identify positive and negative signals for all HTO
			Idents(object = object, cells = names(x = init.clusters$cluster)) <- init.clusters$cluster
		},
		'clara' = {
			#use fast k-medoid clustering
			init.clusters <- clara(
				x = t(x = data),
				k = ncenters,
				samples = nsamples
			)
			#identify positive and negative signals for all HTO
			Idents(object = object, cells = names(x = init.clusters$clustering), drop = TRUE) <- init.clusters$clustering
		},
		stop("Unknown k-means function ", kfunc, ", please choose from 'kmeans' or 'clara'")
	)

	#average hto signals per cluster
	#work around so we don't average all the RNA levels which takes time
	average.expression <- AverageExpression(
		object = object,
		assays = c(assay),
		slot = 'counts',
		verbose = FALSE
	)[[assay]]

	#create a matrix to store classification result
	discrete <- GetAssayData(object = object, assay = assay)
	discrete[discrete > 0] <- 0
	# for each HTO, we will use the minimum cluster for fitting
	thresholds <- list()
	for (hto in naturalsort::naturalsort(rownames(x = data))) {
		values <- counts[hto, colnames(object)]

		# Take the bottom 2 clusters (top 2 assumed to be HTO and doublet) as background.
		maxPossibleBackgroundCols <- max(nrow(data) - 2, 1)
		numBackgroundCols <- min(2, maxPossibleBackgroundCols)
		backgroundIndices <- order(average.expression[hto, ])[1:numBackgroundCols]

		if (sum(average.expression[hto, backgroundIndices]) == 0) {
			allPossibleBackgroundIndices <- order(average.expression[hto, ])[1:maxPossibleBackgroundCols]
			for (i in 1:maxPossibleBackgroundCols) {
				print('Expanding clusters until non-zero background obtained')
				backgroundIndices <- allPossibleBackgroundIndices[1:i]
				if (sum(average.expression[hto, backgroundIndices]) > 0) {
					break
				}
			}
		}

		if (verbose) {
			print(paste0('Will select bottom ', numBackgroundCols, ' barcodes as background'))
			print(paste0('Background clusters for ', hto, ': ', paste0(backgroundIndices, collapse = ',')))
		}

		if (sum(average.expression[hto, backgroundIndices]) == 0) {
			#TODO: unclear what to do with this?
			print('The background clusters have zero reads, cannot call')
			cutoff <- 100
		} else {
			values.use <- values[WhichCells(
				object = object,
				idents = levels(x = Idents(object = object))[backgroundIndices]
			)]

			if (verbose) {
				print(paste0('total cells for background: ', length(values.use)))
			}

			cutoff <- NULL
			tryCatch(expr = {
				fit <- suppressWarnings(fitdist(data = values.use, distr = "nbinom"))
				if (plotDist) {
					print(plot(fit))
				}

				cutoff <- as.numeric(x = quantile(x = fit, probs = positive.quantile)$quantiles[1])
			}, error = function(e) {
				saveRDS(values.use, file = paste0('./', hto, '.fail.nbinom.rds'))
			})

			if (is.null(cutoff)) {
				print(paste0('Skipping HTO due to failure to fit distribution: ', hto))
				next
			}
		}

		if (verbose) {
			print(paste0("Cutoff for ", hto, " : ", cutoff, " reads"))
		}
		discrete[hto, names(x = which(x = values > cutoff))] <- 1

		if (verbose) {
			#P1 <- VlnPlot(average.expression, features = c(hto))
			#P1 <- P1 + geom_hline(intercept = cutoff) + ggtitle(paste0('HTODemux Cutoff: ', hto))
			#print(P1)
		}
	}

	# now assign cells to HTO based on discretized values
	npositive <- colSums(x = discrete)
	classification.global <- npositive
	classification.global[npositive == 0] <- "Negative"
	classification.global[npositive == 1] <- "Singlet"
	classification.global[npositive > 1] <- "Doublet"
	donor.id = rownames(x = data)
	hash.max <- apply(X = data, MARGIN = 2, FUN = max)
	hash.maxID <- apply(X = data, MARGIN = 2, FUN = which.max)
	hash.second <- apply(X = data, MARGIN = 2, FUN = MaxN, N = 2)
	hash.maxID <- as.character(x = donor.id[sapply(
		X = 1:ncol(x = data),
		FUN = function(x) {
			return(which(x = data[, x] == hash.max[x])[1])
		}
	)])
	hash.secondID <- as.character(x = donor.id[sapply(
		X = 1:ncol(x = data),
		FUN = function(x) {
			return(which(x = data[, x] == hash.second[x])[1])
		}
	)])
	hash.margin <- hash.max - hash.second
	doublet_id <- sapply(
		X = 1:length(x = hash.maxID),
		FUN = function(x) {
			return(paste(sort(x = c(hash.maxID[x], hash.secondID[x])), collapse = "_"))
		}
	)

	classification <- classification.global
	classification[classification.global == "Negative"] <- "Negative"
	classification[classification.global == "Singlet"] <- hash.maxID[which(x = classification.global == "Singlet")]
	classification[classification.global == "Doublet"] <- "Doublet" #doublet_id[which(x = classification.global == "Doublet")]
	classification.metadata <- data.frame(
		hash.maxID,
		hash.secondID,
		hash.margin,
		classification,
		classification.global
	)

	suffix <- 'htodemux'
	colnames(x = classification.metadata) <- paste(c('maxID', 'secondID', 'margin', 'classification', 'classification.global'), suffix, sep = '.')
	object <- AddMetaData(object = object, metadata = classification.metadata)

	return(object)
}