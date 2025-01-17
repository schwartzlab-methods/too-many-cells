{- TooManyCells.Spatial.Relationships
Gregory W. Schwartz

Collects the functions pertaining to quantifying relationships between points.
-}

{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}

module TooManyCells.Spatial.Relationships
    ( spatialRelationshipsR
    ) where

-- Remote
import BirchBeer.Types (LabelMap (..))
import Data.Bool (bool)
import Data.Maybe (isJust)
import Language.R as R
import Language.R.QQ (r)

-- Local
import TooManyCells.File.Types (OutputDirectory (..))
import TooManyCells.Matrix.Types (SingleCells (..), ProjectionMap (..), X (..), Y (..))
import TooManyCells.Matrix.Utility (sparseMatToSparseRMat)
import TooManyCells.Spatial.Utility (scToRPat)
import qualified TooManyCells.Spatial.Types as Too

spatialRelationshipsR :: OutputDirectory
                      -> Too.PCFCrossFlag
                      -> ProjectionMap
                      -> Maybe LabelMap
                      -> SingleCells
                      -> Maybe Too.TopDistances
                      -> [Too.Mark]
                      -> IO ()
spatialRelationshipsR (OutputDirectory outDir) pcfCrossFlag' pm lm sc td marks = R.runRegion $ do
  let isLabelMarks = bool 0 1 . isJust $ lm :: Double
      pcfCrossFlagDouble = bool 0 1 $ Too.unPCFCrossFlag pcfCrossFlag' :: Double
      (tVal, tQFlag) = case td of
                        Nothing -> (10, 1 :: Double)
                        Just (Too.TopQuantile x) -> (x :: Double, 1)
                        Just (Too.TopDistance x) -> (x :: Double, 0)

  pat <- scToRPat lm pm sc marks

  [r|
    suppressMessages(library(spatstat))
    suppressMessages(library(reshape2))
    suppressMessages(library(plyr))

    # Find index of first switch from above to below or equal value.
    findNegSwap = function(x, xs) {
      if(all(xs$obs > x)) {
        return(xs$r[length(xs$r)])
      } else if(all(xs$obs <= x)) {
        return(xs$r[1])
      } else {
        for (i in c(1:length(xs$r))) {
          if (i == length(xs$r)) {
            return(xs$r[i])
          } else if ((xs$obs[i] > x) && (xs$obs[i + 1] <= x)) {
            return(xs$r[i + 1])
          }
        }
      }
    }

    # Find index of first switch from below or equal value to above.
    findPosSwap = function(x, xs) {
      if (all(xs$obs <= x)) {
        return(xs$r[length(xs$r)])
      } else if (all(xs$obs > x)) {
        return(xs$r[1])
      } else {
        for (i in c(1:length(xs$r))) {
          if (i == length(xs$r)) {
            return(xs$r[i])
          } else if (xs$obs[i] <= x && xs$obs[i + 1] > x) {
            return(xs$r[i + 1])
          }
        }
      }
    }

    # Find the longest length of a continuously positive (or negative / equal to) stretch.
    findLongestLength = function(posFlag, x, xs) {
      if(posFlag) {
        lengthInfo = rle(xs$obs > x)
      } else {
        lengthInfo = rle(xs$obs <= x)
      }
      stretches = lengthInfo$lengths[which(lengthInfo$values)]
      if(length(stretches) == 0) {
        return(0)
      } else {
        return(xs$r[max(stretches)] - xs$r[1])
      }
    }

    # Find the first r value of the maximum value.
    findMaxPos = function(xs) {
      return(xs$r[min(which(xs$obs == max(xs$obs)))])
    }

    # Find the first r value of the maximum value with maximum value.
    findMaxPosWithVal = function(as) {
      # Do not use 0 values
      xs = as[-1,]
      r = findMaxPos(xs)
      val = max(xs$obs)

      return(val / r)
    }

    # Find the first r value of the minimum value.
    findMinPos = function(xs) {
      return(xs$r[min(which(xs$obs == min(xs$obs)))])
    }

    topDistances = function(xs) {
      if(tQFlag_hs == 1) {
        return(xs$obs[1:round(length(xs$obs) / tVal_hs)])
      } else {
        return(xs$obs[1:max(which(xs$r <= tVal_hs))])
      }
    }

    # Find statistics for a single curve
    getCurveStats = function (outFolder, df) {
      statsDf = data.frame(meanCorr = mean(df$obs))
      statsDf$maxCorr = max(df$obs)
      statsDf$minCorr = min(df$obs)
      statsDf$meanCorr = mean(df$obs)
      statsDf$topMaxCorr = max(topDistances(df))
      statsDf$topMeanCorr = mean(topDistances(df))
      statsDf$topMinCorr = min(topDistances(df))
      statsDf$negSwap = findNegSwap(1, df)
      statsDf$posSwap = findPosSwap(1, df)
      statsDf$longestPosLength = findLongestLength(TRUE, 1, df)
      statsDf$longestNegLength = findLongestLength(FALSE, 1, df)
      statsDf$maxPosWithVal = findMaxPosWithVal(df)
      statsDf$logMaxPosWithVal = log(findMaxPosWithVal(df))
      statsDf$maxPos = findMaxPos(df)
      statsDf$minPos = findMinPos(df)
      statsDf$label = basename(outFolder)
      statsDf$topVal = tVal_hs
      statsDf$topQuantile = tQFlag_hs

      return(statsDf)
    }

    crossCorrCurveStats = function (outFolder) {

      # Cross correlation function (several columns of marks).
      if(pcfCrossFlagDouble_hs == 1) {
        crossFn = envelope(pat_hs, pcfcross, funargs=marks)
        crossFn$obs = crossFn$iso
      } else {
        crossFn = markcrosscorr(pat_hs)
        for(i in c(1:length(crossFn$fns))) {
          crossFn$fns[[i]]$obs = crossFn$fns[[i]]$iso
        }
      }
      plot(crossFn)

      # Object
      outObject = crossFn
      outObject$label = basename(outFolder)
      saveRDS(outObject, file = file.path(outFolder,"crosscorr.rds"))

      # Statistics
      if(pcfCrossFlagDouble_hs == 1) {
        statsDf = getCurveStats(outFolder, crossFn)
      } else {
        varDf = melt(crossFn$which)
        varDf = varDf[order(varDf$value),]
        statsDf = cbind(varDf, do.call(rbind, lapply(crossFn$fns, function (x) getCurveStats(outFolder, x))))
      }

      # To get the sample size, different for quantitative vs. nominal marks
      markVars = marks(pat_hs)
      if (is.data.frame(markVars)) {
        statsDf$n = nrow(markVars)
      } else {
        statsDf$n = length(markVars[markVars != "Other"])
      }

      # Output statistics
      write.csv(statsDf, file.path(outFolder, "stats.csv"), quote = FALSE, row.names = FALSE)

      # Curve
      if(pcfCrossFlagDouble_hs == 1) {
        curveDf = data.frame(x = crossFn$r, y = crossFn$obs, label = basename(outFolder))
      } else {
        curveDf = adply(melt(crossFn$which), 1, function(xs) {
          data.frame(x = crossFn$fns[[xs$value]]$r, y = crossFn$fns[[xs$value]]$obs, label = basename(outFolder))
        })
      }
      write.csv(curveDf, file.path(outFolder, "curve.csv"), quote = FALSE, row.names = FALSE)

      return ()
    }

    mainRelationships = function(isLabelMarks, outFolder) {
      message(paste("Processing", outFolder))
      dir.create(outFolder, showWarnings = FALSE, recursive = TRUE)

      message("Plotting point process")
      pdf(file = file.path(outFolder, "basic_plot.pdf"))
      tryCatch(plot(pat_hs), error = function (e) message(paste("Could not plot basic_plot.pdf:", e)))
      dev.off()

      message("Plotting mark correlation function")
      # Mark correlation function.
      pdf(file = file.path(outFolder, "mark_correlation_function.pdf"))
      tryCatch(plot(markcorr(pat_hs)), error = function (e) message(paste("Could not plot mark_correlation_function.pdf:", e)))
      dev.off()

      # Mark variogram (lower value, more similar mark values at a distance).
      if (!isLabelMarks) {
        message("Plotting variogram")
        pdf(file = file.path(outFolder, "mark_variogram.pdf"))
        tryCatch(plot(markvario(pat_hs)), error = function (e) message(paste("Could not plot mark_variogram:", e)))
        dev.off()
      }

      # Envelope.
      message("Plotting envelope")
      pdf(file = file.path(outFolder, "envelope.pdf"))
      tryCatch(plot(envelope(pat_hs)), error = function (e) message(paste("Could not plot envelope", e)))
      dev.off()

      # Mark cross correlation
      message("Plotting mark cross correlation")
      pdf(file = file.path(outFolder, "cross_correlation_function.pdf"))
      tryCatch(crossCorrCurveStats(outFolder), error = function (e) message(paste("Could not compute mark cross correlation statistics:", e)))
      dev.off()

      return()

    }

    mainRelationships(isLabelMarks_hs, outDir_hs)

  |]

  pure ()
