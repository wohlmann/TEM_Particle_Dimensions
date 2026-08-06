// Elisa PARTICLE SIZE ANALYSIS MACRO

macro "TEM Batch Particle Analysis v24.01 (No Centroid CSV)" {

    // Clear and reset
    print("\\Clear");
    run("Close All");
    run("Clear Results");
    roiManager("reset");

    // config dialog
    Dialog.create("Elisa Particle Analysis");
    Dialog.addMessage("Configure detection:");
    Dialog.addMessage("");
    Dialog.addSlider("Stringency (0=lenient, 100=strict):", 0, 100, 50, 1);
    Dialog.addCheckbox("Generate QC Overlay Images:", true);
    Dialog.addCheckbox("Enable Fusion + Aggregate Detection:", true);
    Dialog.addCheckbox("Apply Watershed:", true);
    Dialog.addCheckbox("ROI Numbers on QC:", true);
    Dialog.addCheckbox("Fusion Pairs Connected Lines:", true);
    Dialog.addCheckbox("Verbose Log (per-pair diagnostics):", false);
    Dialog.addMessage("");
    Dialog.show();

    stringency = Dialog.getNumber();
    qcChecked = Dialog.getCheckbox();
    fusionChecked = Dialog.getCheckbox();
    watershedChecked = Dialog.getCheckbox();
    showNumbersChecked = Dialog.getCheckbox();
    showLinesChecked = Dialog.getCheckbox();
    verboseChecked = Dialog.getCheckbox();

    if (qcChecked == 1) enableQcOutput = 1; else enableQcOutput = 0;
    if (fusionChecked == 1) enableFusion = 1; else enableFusion = 0;
    if (watershedChecked == 1) apply_watershed = 1; else apply_watershed = 0;
    if (showNumbersChecked == 1) showROINumbers = 1; else showROINumbers = 0;
    if (showLinesChecked == 1) showFusionLines = 1; else showFusionLines = 0;
    if (verboseChecked == 1) verbose = 1; else verbose = 0;

    // Calculate thresholds based on stringency
    s = stringency / 100.0;

    min_area_multiplier = 0.15 + (0.15 * s);
    max_area_multiplier = 45.0 - (15.0 * s);
    min_solidity = 0.45 + (0.10 * s);
    max_extent_ratio = 0.90 - (0.10 * s);
    max_aspect_ratio = 4.5 - (1.5 * s);
    max_perim2_area = 55.0 - (15.0 * s);
    borderMargin = 10;
    median_radius = 2;
    contactSmall = 0.04;
    contactConsiderable = 0.14;
    gapTouch = 4.0;

    parallelEdgeMinimum = 2;
    curvatureThreshold = 16.0 - (4.0 * s);
    maxFusionChainMembers = 5;
    maxAspectRatioAfterMerge = 3.5 - (1.0 * s);
    concavityThreshold = 0.45 + (0.10 * s);
    maxSizeRatioFusion = 5.5 - (1.5 * s);
    maxAggregateChainMembers = 18;
    maxIterations = 4;
    // threshold for SHORT vs LONG parallel borders
    minParallelBorderLength = 15.0;

    print("=== TEM Particle Analysis v24.01 (Centroid Columns Removed from CSV) ===");
    print("Stringency: " + stringency + "/100");
    print("  contactSmall=" + d2s(contactSmall*100,0) + "% | contactConsiderable=" + d2s(contactConsiderable*100,0) + "%");
    print("  parallelMin=" + parallelEdgeMinimum + " | curvMax=" + d2s(curvatureThreshold,1) + "°");

    // input/output directories
    inputDir = getDirectory("Select INPUT folder");
    if (inputDir == "") exit("No input folder selected");

    outputDir = getDirectory("Select OUTPUT folder");
    if (outputDir == "") exit("No output folder selected");

    qcSubdir = outputDir + "QC_overlays/";
    resultsPath = outputDir + "particle_results.csv";
    logPath = outputDir + "processing_log.txt";

    File.makeDirectory(qcSubdir);

    //init log
    logContent = "=== Eisa Particle Analysis Log ===\n";
    logContent = logContent + "Input Directory: " + inputDir + "\n";
    logContent = logContent + "Output Directory: " + outputDir + "\n";
    logContent = logContent + "Stringency: " + stringency + "/100\n";

    if (enableFusion == 1) {
        logContent = logContent + "Fusion Detection: Enabled\n";
    } else {
        logContent = logContent + "Fusion Detection: Disabled\n";
    }
    if (apply_watershed == 1) {
        logContent = logContent + "Watershed: Enabled\n";
    } else {
        logContent = logContent + "Watershed: Disabled\n";
    }
    logContent = logContent + "==========================================\n\n";

    fileList = getFileList(inputDir);
    totalFiles = 0;

    for (i = 0; i < lengthOf(fileList); i = i + 1) {
        lowerFname = toLowerCase(fileList[i]);
        if (endsWith(lowerFname, ".tif") || endsWith(lowerFname, ".tiff") ||
            endsWith(lowerFname, ".jpg") || endsWith(lowerFname, ".jpeg") ||
            endsWith(lowerFname, ".png") || endsWith(lowerFname, ".bmp")) {
            totalFiles = totalFiles + 1;
        }
    }

    if (totalFiles == 0) {
        showMessage("No Images Found", "No image files found in: " + inputDir);
        exit();
    }

    showProgress(0, totalFiles);
	//CSV header
    csvHeader = "Filename,Final_Index,Pass1_ROI_Index,Category,Area_px2,Equivalent_Diameter_px,Circularity," +
                 "Min_Feret_px,Max_Feret_px,Bounding_Width_px,Bounding_Height_px," +
                 "Solidity,Extent_Ratio,Aspect_Ratio," +
                 "Perimeter_px,Perim2_Area,Merge_Notes\n";

    csvContent = csvHeader;
    fileIndex = 0;

    grandSingle = 0;
    grandFusion = 0;
    grandAggregate = 0;

    for (fileIdx = 0; fileIdx < lengthOf(fileList); fileIdx = fileIdx + 1) {
        fname = fileList[fileIdx];
        lowerFname = toLowerCase(fname);

        //skip non-image files
        if (!endsWith(lowerFname, ".tif") && !endsWith(lowerFname, ".tiff") &&
            !endsWith(lowerFname, ".jpg") && !endsWith(lowerFname, ".jpeg") &&
            !endsWith(lowerFname, ".png") && !endsWith(lowerFname, ".bmp")) {
            continue;
        }

        fileIndex = fileIndex + 1;
        showProgress(fileIndex, totalFiles);

        logContent = logContent + "\n[" + fileIndex + "/" + totalFiles + "] " + fname + "\n";
        print("\n========== [" + fileIndex + "/" + totalFiles + "] " + fname + " ==========");

        fullPath = inputDir + fname;
        open(fullPath);
        if (nImages == 0) {
            print("  ERROR: Failed to open " + fullPath);
            logContent = logContent + "  STATUS: FAILED - Could not open image\n";
            continue;
        }

        imgWidth = getWidth();
        imgHeight = getHeight();
        origBitDepth = bitDepth;
        baseName = getFileNameWithoutExtension(fname);

        print("  Image: " + imgWidth + "x" + imgHeight + " (" + origBitDepth + "-bit)");
        logContent = logContent + "  Size: " + imgWidth + "x" + imgHeight + " (" + origBitDepth + "-bit)\n";

        // original for QC overlay
        if (enableQcOutput == 1) {
            origImagePath = qcSubdir + baseName + "_ORIGINAL.tif";
            saveAs("Tiff", origImagePath);
        }

        if (origBitDepth != 8) run("8-bit");
        run("Median...", "radius=" + median_radius);

        setOption("BlackBackground", true);
        setAutoThreshold("Otsu dark");
        getThreshold(minThresh, maxThresh);
        run("Convert to Mask");

        getStatistics(areaStat, pixelMean, statMin, statMax, stdDev, histArray);
        whiteFraction = safeDivide(pixelMean, 255.0);

        if (whiteFraction > 0.5) run("Invert");

        if (apply_watershed == 1) run("Watershed");

        // Config measurements
        run("Set Measurements...", "area mean min max bounding shape feret's perimeter solidity extent centroid redirect=None decimal=3");
        run("Clear Results");
        roiManager("reset");

        print("  PASS 1: Detecting contours...");
        logContent = logContent + "  PASS 1: Detecting contours...\n";

        run("Analyze Particles...", "size=0-Infinity show=Outlines display clear add");

        nRaw = roiManager("count");
        print("  >>> PASS 1: " + nRaw + " contours");
        logContent = logContent + "  Contours detected: " + nRaw + "\n";

        if (isOpen("Outlines")) close("Outlines");

        if (nRaw == 0) {
            print("  *** No contours found, skipping.");
            logContent = logContent + "  STATUS: No contours found, skipped\n";
            run("Close All");
            continue;
        }

        // PASS 1 MEASUREMENT STORAGE

        areaArr = newArray(nRaw);
        circArr = newArray(nRaw);
        perimArr = newArray(nRaw);
        solidityArr = newArray(nRaw);
        extentArr = newArray(nRaw);
        minFerArr = newArray(nRaw);
        maxFerArr = newArray(nRaw);
        bwArr = newArray(nRaw);
        bhArr = newArray(nRaw);
        bxArr = newArray(nRaw);
        byArr = newArray(nRaw);
        cxArr = newArray(nRaw);
        cyArr = newArray(nRaw);

        sumArea = 0;
        minAreaRaw = 999999999;
        maxAreaRaw = 0;

        print("  PASS 1b: Measuring each ROI individually...");
        logContent = logContent + "  PASS 1b: Measuring each ROI individually...\n";

        centroidX_col = "XM";
        centroidY_col = "YM";

        run("Clear Results");
        roiManager("select", 0);
        run("Measure");
        headingsStr = getInfo("Results.headings");
        print("  Results headings: " + headingsStr);

        headingStart = 0;
        for (pos = 0; pos <= lengthOf(headingsStr); pos = pos + 1) {
            char = "";
            if (pos < lengthOf(headingsStr)) char = substring(headingsStr, pos, pos + 1);

            if (char == "\n" || pos == lengthOf(headingsStr)) {
                colName = substring(headingsStr, headingStart, pos);
                colName = trim(colName);
                upperName = toUpperCase(colName);

                if (lengthOf(colName) > 0) {
                    if (indexOf(upperName, "X") >= 0) {
                        if (indexOf(upperName, "CENTER") >= 0 || colName == "XM" || colName == "X") {
                            centroidX_col = colName;
                            print("    Found centroid X column: " + colName);
                        }
                    }
                    if (indexOf(upperName, "Y") >= 0) {
                        if (indexOf(upperName, "CENTER") >= 0 || colName == "YM" || colName == "Y") {
                            centroidY_col = colName;
                            print("    Found centroid Y column: " + colName);
                        }
                    }
                }

                headingStart = pos + 1;
            }
        }

        print("  Using centroid columns: " + centroidX_col + " and " + centroidY_col);
        logContent = logContent + "  Centroid columns: " + centroidX_col + ", " + centroidY_col + "\n";

        run("Clear Results");

        for (p = 0; p < nRaw; p = p + 1) {
            roiManager("select", p);
            run("Measure");

            rawArea = getResult("Area", 0);
            rawPerim = getResult("Perim.", 0);
            rawSolidity = getResult("Solidity", 0);
            rawMinFer = getResult("MinFeret", 0);
            rawMaxFer = getResult("Feret", 0);
            rawBw = getResult("Width", 0);
            rawBh = getResult("Height", 0);
            rawBx = getResult("BX", 0);
            rawBy = getResult("BY", 0);

            rawCx = getResult(centroidX_col, 0);
            if (isInvalid(rawCx)) {
                rawCx = getResult("XM", 0);
                if (isInvalid(rawCx)) rawCx = getResult("X", 0);
                if (isInvalid(rawCx)) rawCx = getResult("Center X", 0);
            }

            rawCy = getResult(centroidY_col, 0);
            if (isInvalid(rawCy)) {
                rawCy = getResult("YM", 0);
                if (isInvalid(rawCy)) rawCy = getResult("Y", 0);
                if (isInvalid(rawCy)) rawCy = getResult("Center Y", 0);
            }

            run("Clear Results");

            // Store values
            areaArr[p] = safeValue(rawArea, 0);
            perimArr[p] = safeValue(rawPerim, 0);
            solidityArr[p] = safeValue(rawSolidity, 0);
            minFerArr[p] = safeValue(rawMinFer, 0);
            maxFerArr[p] = safeValue(rawMaxFer, 0);
            bwArr[p] = safeValue(rawBw, 0);
            bhArr[p] = safeValue(rawBh, 0);
            bxArr[p] = safeValue(rawBx, 0);
            byArr[p] = safeValue(rawBy, 0);
            cxArr[p] = safeValue(rawCx, 0);
            cyArr[p] = safeValue(rawCy, 0);

            if (perimArr[p] > 0 && areaArr[p] > 0) {
                circArr[p] = safeDivide(4 * PI * areaArr[p], perimArr[p] * perimArr[p]);
            } else {
                circArr[p] = 0;
            }

            if (bwArr[p] > 0 && bhArr[p] > 0) {
                extentArr[p] = safeDivide(areaArr[p], bwArr[p] * bhArr[p]);
            } else {
                extentArr[p] = 0;
            }

            if (!isInvalid(areaArr[p])) {
                sumArea = sumArea + areaArr[p];
                if (areaArr[p] < minAreaRaw) minAreaRaw = areaArr[p];
                if (areaArr[p] > maxAreaRaw) maxAreaRaw = areaArr[p];
            }
        }

        print("  Stored measurements for " + nRaw + " ROIs");

        // validation (first 3 ROIs)
        if (nRaw >= 3) {
            print("  Validation sample (ROIs 1-3): Circ=" + d2s(circArr[0],3) + "/" + d2s(circArr[1],3) + "/" + d2s(circArr[2],3));
            print("  Validation sample (ROIs 1-3): Extent=" + d2s(extentArr[0],3) + "/" + d2s(extentArr[1],3) + "/" + d2s(extentArr[2],3));
            print("  Validation sample (ROIs 1-3): CX=" + d2s(cxArr[0],1) + "/" + d2s(cxArr[1],1) + "/" + d2s(cxArr[2],1));
            print("  Validation sample (ROIs 1-3): CY=" + d2s(cyArr[0],1) + "/" + d2s(cyArr[1],1) + "/" + d2s(cyArr[2],1));
            logContent = logContent + "  Measurement validation: Circ=" + d2s(circArr[0],3) + "/" + d2s(circArr[1],3) + "/" + d2s(circArr[2],3) + " | Extent=" + d2s(extentArr[0],3) + "/" + d2s(extentArr[1],3) + "/" + d2s(extentArr[2],3) + " | CX=" + d2s(cxArr[0],1) + "/" + d2s(cxArr[1],1) + "/" + d2s(cxArr[2],1) + "\n";
        }

        avgAreaRaw = safeDivide(sumArea, nRaw);
        print("  Area: min=" + d2s(minAreaRaw,0) + " avg=" + d2s(avgAreaRaw,0) + " max=" + d2s(maxAreaRaw,0));
        logContent = logContent + "  Area stats: min=" + d2s(minAreaRaw,0) + " avg=" + d2s(avgAreaRaw,0) + " max=" + d2s(maxAreaRaw,0) + "\n";

        // filtering thresholds
        dynamicMinArea = avgAreaRaw * min_area_multiplier;
        dynamicMaxArea = avgAreaRaw * max_area_multiplier;

        // PASS 2: filter based on quality criteria
        toKeep = newArray(nRaw);
        for (p = 0; p < nRaw; p = p + 1) toKeep[p] = 0;

        pass2OrigIdx = newArray(nRaw);
        validCount = 0;

        for (p = 0; p < nRaw; p = p + 1) {
            area = areaArr[p];
            solidity = solidityArr[p];
            extent = extentArr[p];
            minFer = minFerArr[p];
            maxFer = maxFerArr[p];
            bw = bwArr[p];
            bh = bhArr[p];
            bx = bxArr[p];
            by = byArr[p];
            perim = perimArr[p];

            if (minFer > 0) {
                aspectRatio = safeDivide(maxFer, minFer);
            } else {
                aspectRatio = 999;
            }

            if (perim > 0 && area > 0) {
                perim2area = (perim * perim) / area;
            } else {
                perim2area = 999;
            }

            touchesBorder = 0;
            if (bx <= borderMargin || by <= borderMargin ||
                (bx + bw) >= (imgWidth - borderMargin) ||
                (by + bh) >= (imgHeight - borderMargin)) {
                touchesBorder = 1;
            }

            passes = 1;

            if (isInvalid(area) || area < dynamicMinArea || area > dynamicMaxArea) passes = 0;
            else if (touchesBorder == 1) passes = 0;
            else if (solidity < min_solidity) passes = 0;
            else if (extent > max_extent_ratio) passes = 0;
            else if (aspectRatio > max_aspect_ratio) passes = 0;
            else if (perim2area > max_perim2_area) passes = 0;

            if (passes == 1) {
                pass2OrigIdx[validCount] = p;
                toKeep[p] = 1;
                validCount = validCount + 1;
            }
        }

        print("  PASS 2: " + validCount + "/" + nRaw + " valid");
        logContent = logContent + "  PASS 2: " + validCount + "/" + nRaw + " valid\n";

        particleCategory = newArray(nRaw);
        for (p = 0; p < nRaw; p = p + 1) particleCategory[p] = "SINGLE";

        skipDueToFusion = newArray(nRaw);
        mergeNotesByOrig = newArray(nRaw);
        for (p = 0; p < nRaw; p = p + 1) {
            skipDueToFusion[p] = 0;
            mergeNotesByOrig[p] = "NONE";
        }

        inFusionChain = newArray(nRaw);
        for (p = 0; p < nRaw; p = p + 1) inFusionChain[p] = 0;

        fusionGroupParent = newArray(nRaw);
        for (g = 0; g < nRaw; g = g + 1) fusionGroupParent[g] = g;

        aggGroupParent = newArray(nRaw);
        for (g = 0; g < nRaw; g = g + 1) aggGroupParent[g] = g;

        totalSuccessfulMerges = 0;
        fArea = newArray(nRaw);
        fPerim = newArray(nRaw);
        fCirc = newArray(nRaw);
        fSolidity = newArray(nRaw);
        fExtent = newArray(nRaw);
        fMinFer = newArray(nRaw);
        fMaxFer = newArray(nRaw);
        fBw = newArray(nRaw);
        fBh = newArray(nRaw);
        fBx = newArray(nRaw);
        fBy = newArray(nRaw);
        fCx = newArray(nRaw);
        fCy = newArray(nRaw);
        fP1Idx = newArray(nRaw);
        fP2Idx = newArray(nRaw);
        fStatus = newArray(nRaw);

        totalAggregatesFlagged = 0;

        // Classify  fusion/aggregation
        if (enableFusion == 1 && validCount > 1) {
            print("  CLASSIFICATION: Evaluating contacts ...");
            logContent = logContent + "  CLASSIFICATION: Fusion/Aggregate detection enabled\n";

            for (iter = 1; iter <= maxIterations; iter = iter + 1) {
                nIterationChanges = 0;

                newImage("mergeHelper", "8-bit Black", imgWidth, imgHeight, 1);

                for (v1 = 0; v1 < validCount - 1; v1 = v1 + 1) {
                    for (v2 = v1 + 1; v2 < validCount; v2 = v2 + 1) {

                        p1 = pass2OrigIdx[v1];
                        p2 = pass2OrigIdx[v2];

                        // Skip if classified or in fusion chain
                        if (skipDueToFusion[p1] == 1 || skipDueToFusion[p2] == 1) continue;
                        if (inFusionChain[p1] == 1 || inFusionChain[p2] == 1) {
                            if (verbose == 1) print("    SKIP: Already in fusion chain");
                            continue;
                        }

                        // bounding box gap
                        bb1_x1 = bxArr[p1]; bb1_y1 = byArr[p1];
                        bb1_x2 = bxArr[p1] + bwArr[p1]; bb1_y2 = byArr[p1] + bhArr[p1];

                        bb2_x1 = bxArr[p2]; bb2_y1 = byArr[p2];
                        bb2_x2 = bb2_x1 + bwArr[p2]; bb2_y2 = bb2_y1 + bhArr[p2];

                        if (bb1_x2 <= bb2_x1) gapX = bb2_x1 - bb1_x2;
                        else if (bb2_x2 <= bb1_x1) gapX = bb1_x1 - bb2_x2;
                        else gapX = 0;

                        if (bb1_y2 <= bb2_y1) gapY = bb2_y1 - bb1_y2;
                        else if (bb2_y2 <= bb1_y1) gapY = bb1_y1 - bb2_y2;
                        else gapY = 0;

                        maxGap = maxOf(gapX, gapY);

                        if (maxGap > gapTouch) continue;

                        // contact ratio
                        overlapX = maxOf(0, minOf(bb1_x2, bb2_x2) - maxOf(bb1_x1, bb2_x1));
                        overlapY = maxOf(0, minOf(bb1_y2, bb2_y2) - maxOf(bb1_y1, bb2_y1));
                        contactLen = maxOf(overlapX, overlapY);

                        avgPerim = (perimArr[p1] + perimArr[p2]) / 2;
                        if (avgPerim > 0) contactRatio = contactLen / avgPerim;
                        else contactRatio = 0;

                        if (contactRatio < contactSmall) continue;

                        aggRoot1 = findGroup(aggGroupParent, p1);
                        aggRoot2 = findGroup(aggGroupParent, p2);
                        if (aggRoot1 == aggRoot2) continue;

                        if (verbose == 1) {
                            print("  CHECK " + (p1+1) + "+" + (p2+1) + ": gap=" + d2s(maxGap,1) + "px contact=" + d2s(contactRatio*100,1) + "%");
                        }

                        fusionRoot1 = findGroup(fusionGroupParent, p1);
                        fusionRoot2 = findGroup(fusionGroupParent, p2);

                        fusionMembers1 = newArray(maxFusionChainMembers);
                        fusionMembers2 = newArray(maxFusionChainMembers);
                        nFusionMembers1 = getChainMembers(fusionGroupParent, fusionRoot1, fusionMembers1);
                        nFusionMembers2 = getChainMembers(fusionGroupParent, fusionRoot2, fusionMembers2);

                        aggMembers1 = newArray(maxAggregateChainMembers);
                        aggMembers2 = newArray(maxAggregateChainMembers);
                        nAggMembers1 = getChainMembers(aggGroupParent, aggRoot1, aggMembers1);
                        nAggMembers2 = getChainMembers(aggGroupParent, aggRoot2, aggMembers2);

                        attemptFusion = 1;
                        fusionFailed = 0;

                        // size ratio
                        larger = maxOf(areaArr[p1], areaArr[p2]);
                        smaller = minOf(areaArr[p1], areaArr[p2]);
                        if (smaller > 0) sizeRatio = larger / smaller;
                        else sizeRatio = 999;

                        if (sizeRatio > maxSizeRatioFusion) {
                            attemptFusion = 0;
                            fusionFailed = 1;
                        }
                        if ((nFusionMembers1 + nFusionMembers2) > maxFusionChainMembers) {
                            attemptFusion = 0;
                            fusionFailed = 1;
                        }
                        if (contactRatio < contactConsiderable) {
                            attemptFusion = 0;
                            fusionFailed = 1;
                        }

                        if (attemptFusion == 1) {
                            roiManager("select", p1);
                            getSelectionCoordinates(x1_pts, y1_pts);
                            nPts1 = lengthOf(x1_pts);

                            roiManager("select", p2);
                            getSelectionCoordinates(x2_pts, y2_pts);
                            nPts2 = lengthOf(x2_pts);

                            if (nPts1 >= 10 && nPts2 >= 10) {
                                contactIdx1 = findTrueContactPoint(x1_pts, y1_pts, x2_pts, y2_pts);
                                contactIdx2 = findTrueContactPoint(x2_pts, y2_pts, x1_pts, y1_pts);

                                segmentSize = maxOf(5, floor(perimArr[p1] / 30));
                                if (segmentSize > 12) segmentSize = 12;

                                curvatureWinSize = maxOf(3, floor(segmentSize / 2));
                                if (curvatureWinSize < 3) curvatureWinSize = 3;

                                curvature1 = calculateCurvatureLocal(x1_pts, y1_pts, curvatureWinSize, contactIdx1);
                                curvature2 = calculateCurvatureLocal(x2_pts, y2_pts, curvatureWinSize, contactIdx2);
                                avgCurvature = (curvature1 + curvature2) / 2;

                                parEdges1 = countParallelEdgesNearContact(x1_pts, y1_pts, contactIdx1, perimArr[p1], segmentSize);
                                parEdges2 = countParallelEdgesNearContact(x2_pts, y2_pts, contactIdx2, perimArr[p2], segmentSize);
                                totalParallelEdges = parEdges1 + parEdges2;

                                if (verbose == 1) {
                                    print("    par1=" + parEdges1 + " par2=" + parEdges2 + " curv=" + d2s(avgCurvature,1) + "°");
                                }

                                if (totalParallelEdges >= parallelEdgeMinimum && avgCurvature <= curvatureThreshold) {

                                    selectImage("mergeHelper");
                                    run("Select All");
                                    setForegroundColor(0, 0, 0);
                                    run("Fill");
                                    setForegroundColor(255, 255, 255);
                                    run("Select None");

                                    roiManager("select", p1);
                                    selectImage("mergeHelper");
                                    run("Fill");
                                    roiManager("select", p2);
                                    selectImage("mergeHelper");
                                    run("Fill");

                                    run("Set Measurements...", "area mean min max bounding shape feret's perimeter solidity extent centroid redirect=None decimal=3");
                                    run("Clear Results");
                                    run("Analyze Particles...", "size=0-Infinity clear");

                                    if (isOpen("Outlines")) close("Outlines");

                                    if (nResults == 1) {
                                        mergedArea_val = safeValue(getResult("Area", 0), 0);
                                        mergedPerim_val = safeValue(getResult("Perim.", 0), 0);
                                        mergedSolidity_val = safeValue(getResult("Solidity", 0), 0);
                                        mergedMinFer_val = safeValue(getResult("MinFeret", 0), 0);
                                        mergedMaxFer_val = safeValue(getResult("Feret", 0), 0);
                                        mergedBw_val = safeValue(getResult("Width", 0), 0);
                                        mergedBh_val = safeValue(getResult("Height", 0), 0);
                                        mergedBx_val = safeValue(getResult("BX", 0), 0);
                                        mergedBy_val = safeValue(getResult("BY", 0), 0);
                                        mergedCx_val = safeValue(getResult("XM", 0), 0);
                                        mergedCy_val = safeValue(getResult("YM", 0), 0);

                                        selectImage("mergeHelper");
                                        run("Select None");
                                        run("Clear Results");

                                        // validate shape
                                        if (mergedArea_val > 0 && mergedPerim_val > 0 && mergedSolidity_val > 0) {
                                            mergedAR = 0;
                                            if (mergedMinFer_val > 0) mergedAR = mergedMaxFer_val / mergedMinFer_val;

                                            mergedTouchesBorder = 0;
                                            if (mergedBx_val <= borderMargin || mergedBy_val <= borderMargin ||
                                                (mergedBx_val + mergedBw_val) >= (imgWidth - borderMargin) ||
                                                (mergedBy_val + mergedBh_val) >= (imgHeight - borderMargin)) {
                                                mergedTouchesBorder = 1;
                                            }

                                            shapeOK = 1;
                                            if (mergedAR > maxAspectRatioAfterMerge) shapeOK = 0;
                                            if (mergedSolidity_val < concavityThreshold) shapeOK = 0;
                                            if (mergedTouchesBorder == 1) shapeOK = 0;

                                            if (shapeOK == 1) {
                                                idx = totalSuccessfulMerges;
                                                fArea[idx] = mergedArea_val;
                                                fPerim[idx] = mergedPerim_val;
                                                fCirc[idx] = safeDivide(4*PI*mergedArea_val, mergedPerim_val*mergedPerim_val);
                                                fSolidity[idx] = mergedSolidity_val;
                                                fExtent[idx] = safeDivide(mergedArea_val, mergedBw_val*mergedBh_val);
                                                fMinFer[idx] = mergedMinFer_val;
                                                fMaxFer[idx] = mergedMaxFer_val;
                                                fBw[idx] = mergedBw_val;
                                                fBh[idx] = mergedBh_val;
                                                fBx[idx] = mergedBx_val;
                                                fBy[idx] = mergedBy_val;
                                                fCx[idx] = mergedCx_val;
                                                fCy[idx] = mergedCy_val;
                                                fP1Idx[idx] = p1;
                                                fP2Idx[idx] = p2;
                                                fStatus[idx] = "SUCCESSFUL";

                                                skipDueToFusion[p1] = 1;
                                                skipDueToFusion[p2] = 1;
                                                particleCategory[p1] = "FUSION";
                                                particleCategory[p2] = "FUSION";
                                                mergeNotesByOrig[p1] = "FUSED_WITH_" + (p2 + 1);
                                                mergeNotesByOrig[p2] = "FUSED_WITH_" + (p1 + 1);
                                                inFusionChain[p1] = 1;
                                                inFusionChain[p2] = 1;

                                                unionGroups(fusionGroupParent, p1, p2);

                                                totalSuccessfulMerges = totalSuccessfulMerges + 1;
                                                nIterationChanges = nIterationChanges + 1;

                                                if (verbose == 1) {
                                                    print("    -> FUSION (par=" + totalParallelEdges + " curv=" + d2s(avgCurvature,1) + "°)");
                                                }
                                                continue;
                                            }
                                        }
                                    }
                                    selectImage("mergeHelper");
                                    run("Select None");
                                    run("Clear Results");
                                }
                                fusionFailed = 1;  // criteria failed
                            } else {
                                fusionFailed = 1;  // Not enough points
                            }
                        }

                        // AGGREGATE
                        if (fusionFailed == 1 && contactRatio >= contactConsiderable) {
                            if ((nAggMembers1 + nAggMembers2) <= maxAggregateChainMembers) {
                                if (particleCategory[p1] != "AGGREGATE") {
                                    particleCategory[p1] = "AGGREGATE";
                                    totalAggregatesFlagged = totalAggregatesFlagged + 1;
                                    nIterationChanges = nIterationChanges + 1;
                                }
                                if (particleCategory[p2] != "AGGREGATE") {
                                    particleCategory[p2] = "AGGREGATE";
                                    totalAggregatesFlagged = totalAggregatesFlagged + 1;
                                    nIterationChanges = nIterationChanges + 1;
                                }

                                unionGroups(aggGroupParent, p1, p2);

                                aggRoot = findGroup(aggGroupParent, p1);
                                mergeNotesByOrig[p1] = "IN_AGGREGATE_" + (aggRoot+1);
                                mergeNotesByOrig[p2] = "IN_AGGREGATE_" + (aggRoot+1);

                                if (verbose == 1) {
                                    print("    -> AGGREGATE (FUSION failed, contact=" + d2s(contactRatio*100,1) + "%)");
                                }
                                continue;
                            }
                        }

                        if (verbose == 1) {
                            print("    -> SINGLE (contact=" + d2s(contactRatio*100,1) + "% or fusion not attempted)");
                        }
                    }
                }

                selectImage("mergeHelper");
                close();

                if (nIterationChanges == 0) break;
            }

            print("  Classification: FUSION=" + totalSuccessfulMerges + " | AGGREGATE=" + totalAggregatesFlagged);
            logContent = logContent + "  Classification: FUSION=" + totalSuccessfulMerges + " | AGGREGATE=" + totalAggregatesFlagged + "\n";
        } else {
            print("  CLASSIFICATION: Skipped (fusion disabled or validCount<=1)");
            logContent = logContent + "  CLASSIFICATION: Skipped (fusion disabled or validCount<=1)\n";
        }

        nSingleKept = 0;
        nAggregateKept = 0;
        for (p = 0; p < nRaw; p = p + 1) {
            if (toKeep[p] == 1 && skipDueToFusion[p] == 0) {
                if (particleCategory[p] == "AGGREGATE") nAggregateKept = nAggregateKept + 1;
                else nSingleKept = nSingleKept + 1;
            }
        }
        nFinalKept = nSingleKept + nAggregateKept + totalSuccessfulMerges;

        doubleCountCheck = 0;
        for (p = 0; p < nRaw; p = p + 1) {
            if (toKeep[p] == 1) {
                if (skipDueToFusion[p] == 1) {
                    if (particleCategory[p] != "FUSION") {
                        print("  WARNING: Particle " + (p+1) + " skipped but not FUSION!");
                        doubleCountCheck = doubleCountCheck + 1;
                    }
                } else {
                    if (particleCategory[p] == "FUSION") {
                        print("  WARNING: Particle " + (p+1) + " not skipped but marked FUSION!");
                        doubleCountCheck = doubleCountCheck + 1;
                    }
                }
            }
        }
        if (doubleCountCheck > 0) {
            print("  ERROR: " + doubleCountCheck + " double-counting issues detected!");
            logContent = logContent + "  DOUBLE-COUNTING ERROR: " + doubleCountCheck + " issues!\n";
        } else {
            print("  Verification: No double-counting detected ✓");
            logContent = logContent + "  Verification: No double-counting detected\n";
        }

        grandSingle = grandSingle + nSingleKept;
        grandFusion = grandFusion + totalSuccessfulMerges;
        grandAggregate = grandAggregate + nAggregateKept;

        print("  FINAL: SINGLE=" + nSingleKept + " | FUSION=" + totalSuccessfulMerges + " | AGGREGATE=" + nAggregateKept + " = " + nFinalKept);
        logContent = logContent + "  FINAL: SINGLE=" + nSingleKept + " | FUSION=" + totalSuccessfulMerges + " | AGGREGATE=" + nAggregateKept + " = " + nFinalKept + "\n";
        logContent = logContent + "  STATUS: SUCCESS\n";

        finalIdx = 0;

        // CSV
        for (p = 0; p < nRaw; p = p + 1) {
            if (toKeep[p] == 1 && skipDueToFusion[p] == 0) {
                finalIdx = finalIdx + 1;

                area_p = areaArr[p];
                circ_p = circArr[p];
                perim_p = perimArr[p];
                solidity_p = solidityArr[p];
                extent_p = extentArr[p];
                minFer_p = minFerArr[p];
                maxFer_p = maxFerArr[p];
                bw_p = bwArr[p];
                bh_p = bhArr[p];
                cx_p = cxArr[p];
                cy_p = cyArr[p];

                eqDiam = sqrt(safeDivide(area_p, PI) * 4);

                if (minFer_p > 0) {
                    ar_p = safeDivide(maxFer_p, minFer_p);
                } else {
                    ar_p = 0;
                }

                if (area_p > 0) {
                    p2a_p = safeDivide(perim_p*perim_p, area_p);
                } else {
                    p2a_p = 0;
                }

                cat = particleCategory[p];

                notes = mergeNotesByOrig[p];
                if (notes == "NONE") {
                    notes = "SINGLE";
                }

                row = baseName + "," + finalIdx + "," + (p+1) + "," + cat + "," +
                      d2s(area_p,1) + "," + d2s(eqDiam,1) + "," + d2s(circ_p,3) + "," +
                      d2s(minFer_p,1) + "," + d2s(maxFer_p,1) + "," + d2s(bw_p,1) + "," +
                      d2s(bh_p,1) + "," +
                      d2s(solidity_p,3) + "," + d2s(extent_p,3) + "," + d2s(ar_p,3) + "," +
                      d2s(perim_p,1) + "," + d2s(p2a_p,1) + "," +
                      notes + "\n";
                csvContent = csvContent + row;
            }
        }

        // CSV OUT

        for (m = 0; m < totalSuccessfulMerges; m = m + 1) {
            finalIdx = finalIdx + 1;
            p1 = fP1Idx[m];
            eqDiam_m = sqrt(safeDivide(fArea[m], PI) * 4);

            if (fMinFer[m] > 0) {
                ar_m = safeDivide(fMaxFer[m], fMinFer[m]);
            } else {
                ar_m = 0;
            }

            p2a_m = safeDivide(fPerim[m]*fPerim[m], fArea[m]);

            row = baseName + "," + finalIdx + "," + (p1+1) + "," +
                  "FUSION," +
                  d2s(fArea[m],1) + "," + d2s(eqDiam_m,1) + "," + d2s(fCirc[m],3) + "," +
                  d2s(fMinFer[m],1) + "," + d2s(fMaxFer[m],1) + "," + d2s(fBw[m],1) + "," +
                  d2s(fBh[m],1) + "," +
                  d2s(fSolidity[m],3) + "," + d2s(fExtent[m],3) + "," + d2s(ar_m,3) + "," +
                  d2s(fPerim[m],1) + "," + d2s(p2a_m,1) + "," +
                  "FUSED_FROM_" + (fP1Idx[m]+1) + "_" + (fP2Idx[m]+1) + "\n";
            csvContent = csvContent + row;
        }

        print("  CSV: " + finalIdx + " rows");
        logContent = logContent + "  CSV rows: " + finalIdx + "\n";

        // QC OVERLAY
        if (enableQcOutput == 1) {
            while (nImages > 0) { selectImage(1); close(); }
            open(origImagePath);
            if (origBitDepth != 8) run("8-bit");
            run("RGB Color");

            // Draw
            for (p = 0; p < nRaw; p = p + 1) {
                roiManager("select", p);
                if (toKeep[p] == 0) {
                    setForegroundColor(255, 0, 0);
                    lineWidth = 2;
                } else if (skipDueToFusion[p] == 1) {
                    setForegroundColor(255, 255, 0);
                    lineWidth = 2;
                } else if (particleCategory[p] == "AGGREGATE") {
                    setForegroundColor(0, 200, 255);
                    lineWidth = 2;
                } else {
                    setForegroundColor(0, 255, 0);
                    lineWidth = 2;
                }
                setLineWidth(lineWidth);
                run("Draw");
            }

            // fusion  lines
            if (showFusionLines == 1 && totalSuccessfulMerges > 0) {
                setLineWidth(1);
                setColor(255, 255, 0);
                for (m = 0; m < totalSuccessfulMerges; m = m + 1) {
                    p1 = fP1Idx[m];
                    p2 = fP2Idx[m];
                    drawLine(cxArr[p1], cyArr[p1], cxArr[p2], cyArr[p2]);
                }
            }

            // ROI numbers
            if (showROINumbers == 1) {
                fontSize = floor(imgWidth / 100);
                if (fontSize < 20) fontSize = 20;
                if (fontSize > 40) fontSize = 40;

                setFont("SansSerif", fontSize, "bold");

                run("Select None");

                for (p = 0; p < nRaw; p = p + 1) {
                    xText = cxArr[p] - floor(fontSize/5);
                    yText = cyArr[p] + floor(fontSize/10);

                    setColor(0, 0, 0);
                    drawString("" + (p+1), xText - 2, yText - 2);
                    drawString("" + (p+1), xText + 2, yText - 2);
                    drawString("" + (p+1), xText - 2, yText + 2);
                    drawString("" + (p+1), xText + 2, yText + 2);
                    drawString("" + (p+1), xText - 2, yText);
                    drawString("" + (p+1), xText + 2, yText);
                    drawString("" + (p+1), xText, yText - 2);
                    drawString("" + (p+1), xText, yText + 2);

                    setColor(255, 255, 255);
                    drawString("" + (p+1), xText, yText);
                }
            }

            roiManager("reset");

            qcCombinedPath = qcSubdir + baseName + "_QC_COMBINED.png";
            saveAs("PNG", qcCombinedPath);
            print("  Saved QC: " + qcCombinedPath);
            close();
        }

        roiManager("reset");
        run("Clear Results");

        remainingWindows = getList("image.titles");
        for (w = 0; w < lengthOf(remainingWindows); w = w + 1) {
            winTitle = remainingWindows[w];
            if (winTitle != "Results" && winTitle != "Log") {
                selectWindow(winTitle);
                close();
            }
        }
    }

    showProgress(totalFiles, totalFiles);
    File.saveString(csvContent, resultsPath);

    // Save log
    File.saveString(logContent, logPath);

    run("Close All");
    run("Clear Results");

    print("\n========== BATCH COMPLETE ==========");
    print("Processed: " + fileIndex + "/" + totalFiles + " images");
    print("CSV: " + resultsPath);
    print("Log: " + logPath);
    print("Grand totals: SINGLE=" + grandSingle + " | FUSION=" + grandFusion + " | AGGREGATE=" + grandAggregate);
    showMessage("Complete", "Processed " + fileIndex + "/" + totalFiles + " images\n\nTOTALS:\nSINGLE: " + grandSingle + " (green)\nFUSION: " + grandFusion + " (yellow)\nAGGREGATE: " + grandAggregate + " (cyan)\n\nCSV saved to:\n" + resultsPath + "\n\nLog saved to:\n" + logPath);
}

//FUNCTIONS

function getFileNameWithoutExtension(filename) {
    baseName = filename;
    baseName = replace(baseName, ".tif", "");
    baseName = replace(baseName, ".TIF", "");
    baseName = replace(baseName, ".tiff", "");
    baseName = replace(baseName, ".TIFF", "");
    baseName = replace(baseName, ".jpg", "");
    baseName = replace(baseName, ".JPG", "");
    baseName = replace(baseName, ".jpeg", "");
    baseName = replace(baseName, ".JPEG", "");
    baseName = replace(baseName, ".png", "");
    baseName = replace(baseName, ".PNG", "");
    baseName = replace(baseName, ".bmp", "");
    baseName = replace(baseName, ".BMP", "");
    return baseName;
}

function isInvalid(value) {
    if (value == "") return true;
    if (value == "NaN") return true;
    numValue = value * 1;
    if (numValue != numValue) return true;
    if (numValue > 1000000000 || numValue < -1000000000) return true;
    return false;
}

function safeValue(value, defaultValue) {
    if (isInvalid(value)) return defaultValue;
    return value * 1;
}

function safeDivide(num, denom) {
    numVal = safeValue(num, 0);
    denomVal = safeValue(denom, 0);
    if (denomVal == 0) return 0;
    result = numVal / denomVal;
    if (result != result) return 0;
    return result;
}

function maxOf(a, b) {
    if (a > b) return a;
    else return b;
}

function minOf(a, b) {
    if (a < b) return a;
    else return b;
}

function abs(x) {
    if (x < 0) return -x;
    else return x;
}

//parallel edge - dual-length
function countParallelEdgesNearContact(xArr, yArr, contactIdx, totalPerim, segmentSize) {
    nPoints = lengthOf(xArr);
    if (nPoints < segmentSize * 4 + 1) return 0;

    regionStart = contactIdx - floor(lengthOf(xArr) * 0.30);
    regionEnd = contactIdx + floor(lengthOf(xArr) * 0.30);
    if (regionStart < 0) regionStart = 0;
    if (regionEnd >= nPoints) regionEnd = nPoints - 1;

    parallelCount = 0;
    segmentStep = maxOf(3, segmentSize / 2);

    //local parallel
    for (i = regionStart; i < regionEnd - segmentSize * 2; i = i + segmentStep) {
        dx1 = xArr[i + segmentSize] - xArr[i];
        dy1 = yArr[i + segmentSize] - yArr[i];
        dx2 = xArr[i + 2*segmentSize] - xArr[i + segmentSize];
        dy2 = yArr[i + 2*segmentSize] - yArr[i + segmentSize];
        len1 = sqrt(dx1*dx1 + dy1*dy1);
        len2 = sqrt(dx2*dx2 + dy2*dy2);
        if (len1 > 0 && len2 > 0) {
            nx1 = dx1 / len1; ny1 = dy1 / len1;
            nx2 = dx2 / len2; ny2 = dy2 / len2;
            dotProduct = abs(nx1*nx2 + ny1*ny2);
            if (dotProduct > 0.85) parallelCount = parallelCount + 1;
        }
    }

    // parallel borders
    longSegmentSize = maxOf(8, segmentSize * 2);
    for (i = regionStart; i < regionEnd - longSegmentSize * 2; i = i + longSegmentSize / 2) {
        dx1 = xArr[i + longSegmentSize] - xArr[i];
        dy1 = yArr[i + longSegmentSize] - yArr[i];
        dx2 = xArr[i + 2*longSegmentSize] - xArr[i + longSegmentSize];
        dy2 = yArr[i + 2*longSegmentSize] - yArr[i + longSegmentSize];
        len1 = sqrt(dx1*dx1 + dy1*dy1);
        len2 = sqrt(dx2*dx2 + dy2*dy2);
        if (len1 > 0 && len2 > 0) {
            nx1 = dx1 / len1; ny1 = dy1 / len1;
            nx2 = dx2 / len2; ny2 = dy2 / len2;
            dotProduct = abs(nx1*nx2 + ny1*ny2);
            if (dotProduct > 0.92) parallelCount = parallelCount + 1;
        }
    }

    return parallelCount;
}

function calculateCurvatureLocal(xArr, yArr, windowSize, centerIdx) {
    nPoints = lengthOf(xArr);
    if (centerIdx < windowSize || centerIdx >= nPoints - windowSize) return 999;

    dx1 = xArr[centerIdx] - xArr[centerIdx - windowSize];
    dy1 = yArr[centerIdx] - yArr[centerIdx - windowSize];
    dx2 = xArr[centerIdx + windowSize] - xArr[centerIdx];
    dy2 = yArr[centerIdx + windowSize] - yArr[centerIdx];

    len1 = sqrt(dx1*dx1 + dy1*dy1);
    len2 = sqrt(dx2*dx2 + dy2*dy2);

    if (len1 > 0 && len2 > 0) {
        nx1 = dx1 / len1; ny1 = dy1 / len1;
        nx2 = dx2 / len2; ny2 = dy2 / len2;
        dotProduct = nx1*nx2 + ny1*ny2;
        if (dotProduct > 1.0) dotProduct = 1.0;
        if (dotProduct < -1.0) dotProduct = -1.0;
        angle = acos(dotProduct) * 180.0 / PI;
        return angle;
    } else {
        return 999;
    }
}

function findTrueContactPoint(xArr1, yArr1, xArr2, yArr2) {
    minDist = 999999;
    bestIdx = 0;
    for (i = 0; i < lengthOf(xArr1); i = i + 2) {
        for (j = 0; j < lengthOf(xArr2); j = j + 5) {
            dx = xArr1[i] - xArr2[j];
            dy = yArr1[i] - yArr2[j];
            dist = dx*dx + dy*dy;
            if (dist < minDist) {
                minDist = dist;
                bestIdx = i;
            }
        }
    }
    return bestIdx;
}

function findGroup(groupArray, index) {
    root = index;
    while (groupArray[root] != root) root = groupArray[root];
    curr = index;
    while (curr != root) {
        next = groupArray[curr];
        groupArray[curr] = root;
        curr = next;
    }
    return root;
}

function unionGroups(groupArray, index1, index2) {
    root1 = findGroup(groupArray, index1);
    root2 = findGroup(groupArray, index2);
    if (root1 != root2) {
        groupArray[root1] = root2;
        return true;
    }
    return false;
}

function getChainMembers(parentArray, root, outArray) {
    outCount = 0;
    nElements = lengthOf(parentArray);
    queue = newArray(nElements);
    head = 0;
    tail = 0;
    queue[tail] = root;
    tail = tail + 1;
    visited = newArray(nElements);
    for (vi = 0; vi < nElements; vi = vi + 1) visited[vi] = 0;
    visited[root] = 1;

    while (head < tail) {
        curr = queue[head];
        head = head + 1;
        outArray[outCount] = curr;
        outCount = outCount + 1;
        for (ci = 0; ci < nElements; ci = ci + 1) {
            if (visited[ci] == 0 && parentArray[ci] == curr) {
                visited[ci] = 1;
                queue[tail] = ci;
                tail = tail + 1;
            }
        }
    }
    return outCount;
}